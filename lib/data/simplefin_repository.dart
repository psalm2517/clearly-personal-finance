part of 'repository.dart';

/// What one sync did, for showing to the person.
class SimpleFinSyncResult {
  const SimpleFinSyncResult({
    this.newTransactions = 0,
    this.matchedTransactions = 0,
    this.pairedMovements = 0,
    this.recognizedRecurring = 0,
    this.syncedAccounts = 0,
    this.unmappedAccounts = 0,
    this.messages = const [],
    this.failure,
  });

  /// Transactions imported this time (already-seen ones are not counted).
  final int newTransactions;

  /// Feed transactions that turned out to be entries already typed in by
  /// hand. They are claimed rather than added a second time.
  final int matchedTransactions;

  /// Transfers and card payments recognised as the same money leaving one
  /// linked account and arriving in another. They are recorded as movements,
  /// not as spending and income.
  final int pairedMovements;

  /// Bank transactions recognised as a bill paid or a paycheck received.
  final int recognizedRecurring;

  /// Linked accounts whose balance and transactions were refreshed.
  final int syncedAccounts;

  /// Feed accounts still waiting for the person to say where they belong.
  final int unmappedAccounts;

  /// What the Bridge said needs attention (its `errlist`), verbatim.
  final List<String> messages;

  /// Set when the sync could not run at all.
  final String? failure;

  SimpleFinSyncResult plus(SimpleFinSyncResult o) => SimpleFinSyncResult(
    newTransactions: newTransactions + o.newTransactions,
    matchedTransactions: matchedTransactions + o.matchedTransactions,
    pairedMovements: pairedMovements + o.pairedMovements,
    recognizedRecurring: recognizedRecurring + o.recognizedRecurring,
    syncedAccounts: syncedAccounts + o.syncedAccounts,
    unmappedAccounts: unmappedAccounts + o.unmappedAccounts,
    messages: [...messages, ...o.messages],
    failure: failure ?? o.failure,
  );
}

/// Bank sync through the SimpleFIN Bridge.
///
/// Rules this follows:
///  * Nothing is imported until a feed account is linked to an account or
///    card. New feed accounts wait, unmapped, to be reviewed.
///  * The feed is the truth for balances: a linked account's balance is set
///    to what the bank reports, not adjusted by the imported transactions.
///  * Transactions are imported once, keyed by the feed's own ids, so a sync
///    can safely re-read an overlapping window.
///  * Each import is a batch, so it can be undone like a CSV import.
extension SimpleFinRepository on HomebaseRepository {
  /// The Bridge asks for at most 90 days per request and about 5 days of
  /// overlap between runs so late-posting items are not missed.
  static const _window = Duration(days: 90);
  static const _overlap = Duration(days: 5);

  Stream<List<SimpleFinConnection>> watchSimpleFinConnections({
    required int profileId,
  }) => (_db.select(
    _db.simpleFinConnections,
  )..where((c) => c.profileId.equals(profileId))).watch();

  Stream<List<SimpleFinFeedAccount>> watchSimpleFinFeedAccounts({
    required int profileId,
  }) {
    final query = _db.select(_db.simpleFinFeedAccounts).join([
      innerJoin(
        _db.simpleFinConnections,
        _db.simpleFinConnections.id.equalsExp(
          _db.simpleFinFeedAccounts.connectionId,
        ),
      ),
    ])..where(_db.simpleFinConnections.profileId.equals(profileId));
    return query.watch().map(
      (rows) => [for (final r in rows) r.readTable(_db.simpleFinFeedAccounts)],
    );
  }

  /// Claims [setupToken] and lists the accounts it exposes, so they can be
  /// linked. Returns the new connection's id.
  Future<int> connectSimpleFin({
    required int profileId,
    required String setupToken,
    SimpleFinClient? client,
    DateTime? now,
  }) async {
    final c = client ?? SimpleFinClient();
    final access = await c.claim(setupToken);
    final id = await _db
        .into(_db.simpleFinConnections)
        .insert(
          SimpleFinConnectionsCompanion.insert(
            profileId: profileId,
            accessUrl: access,
            createdAt: now ?? DateTime.now(),
          ),
        );
    try {
      final data = await c.fetch(access, balancesOnly: true);
      await _upsertFeedAccounts(id, data.accounts);
      await _setSyncStatus(
        id,
        now ?? DateTime.now(),
        data.errors.isEmpty ? 'Connected' : data.errors.join('; '),
      );
    } on SimpleFinException catch (e) {
      // The claim already succeeded and cannot be repeated, so keep the
      // connection and let the person retry the listing with Sync.
      await _setSyncStatus(id, null, e.message);
    }
    return id;
  }

  /// Refreshes every connection of [profileId]: balances for linked
  /// accounts and any transactions not seen before.
  ///
  /// [lookback], when given, reads that far back regardless of the last
  /// sync, which is what linking a new account needs to pull its history.
  Future<SimpleFinSyncResult> syncSimpleFin({
    required int profileId,
    SimpleFinClient? client,
    DateTime? now,
    Duration? lookback,
  }) async {
    final c = client ?? SimpleFinClient();
    final at = now ?? DateTime.now();
    final connections = await (_db.select(
      _db.simpleFinConnections,
    )..where((x) => x.profileId.equals(profileId))).get();
    var total = const SimpleFinSyncResult();
    for (final conn in connections) {
      total = total.plus(await _syncConnection(conn, c, at, lookback));
    }
    if (connections.isNotEmpty) {
      await recordNetWorthSnapshot(profileId: profileId);
      await recordAccountSnapshotsForToday(profileId: profileId);
    }
    return total;
  }

  Future<SimpleFinSyncResult> _syncConnection(
    SimpleFinConnection conn,
    SimpleFinClient client,
    DateTime now,
    Duration? lookback,
  ) async {
    try {
      var start = lookback != null
          ? now.subtract(lookback)
          : (conn.lastSyncAt == null
                ? now.subtract(_window)
                : conn.lastSyncAt!.subtract(_overlap));
      if (start.isAfter(now)) start = now.subtract(_overlap);

      // One request per 90 day slice, oldest first.
      final transactions = <String, Map<String, SimpleFinTransaction>>{};
      SimpleFinData? latest;
      final messages = <String>[];
      var from = start;
      while (true) {
        final to = from.add(_window).isAfter(now) ? now : from.add(_window);
        final data = await client.fetch(conn.accessUrl, start: from, end: to);
        latest = data;
        messages.addAll(data.errors.map((e) => e.toString()));
        for (final a in data.accounts) {
          final bucket = transactions.putIfAbsent(a.id, () => {});
          for (final t in a.transactions) {
            bucket[t.id] = t;
          }
        }
        if (!to.isBefore(now)) break;
        from = to;
      }

      await _upsertFeedAccounts(conn.id, latest.accounts);

      final feed = await (_db.select(
        _db.simpleFinFeedAccounts,
      )..where((f) => f.connectionId.equals(conn.id))).get();
      var imported = 0;
      var matched = 0;
      var synced = 0;
      final newIds = <int>[];
      var unmapped = 0;
      for (final f in feed) {
        switch (f.target) {
          case FeedTarget.unmapped:
            unmapped++;
          case FeedTarget.ignored:
            break;
          case FeedTarget.account:
          case FeedTarget.card:
          case FeedTarget.loan:
            synced++;
            final r = await _applyFeedAccount(
              profileId: conn.profileId,
              feed: f,
              transactions: (transactions[f.remoteId] ?? {}).values.toList(),
            );
            imported += r.imported;
            matched += r.matched;
            newIds.addAll(r.ids);
        }
      }

      // Money moving between your own accounts is not spending or income:
      // pair it up first, then see which of what is left is a bill or a
      // paycheck you already track.
      final paired = await _pairMovements(conn.profileId, newIds);
      final recognized = await _recognizeRecurring(conn.profileId, newIds);

      await _backfillHistory(
        profileId: conn.profileId,
        feed: feed,
        transactions: transactions,
        start: start,
        now: now,
      );

      final parts = <String>[
        if (imported > 0) '$imported new' else 'Up to date',
        if (paired > 0) '$paired transfers paired',
        if (recognized > 0) '$recognized bills or paychecks matched',
        if (unmapped > 0) '$unmapped to review',
        ...messages,
      ];
      await _setSyncStatus(conn.id, now, parts.join('; '));
      return SimpleFinSyncResult(
        newTransactions: imported,
        matchedTransactions: matched,
        pairedMovements: paired,
        recognizedRecurring: recognized,
        syncedAccounts: synced,
        unmappedAccounts: unmapped,
        messages: messages,
      );
    } on SimpleFinException catch (e) {
      await _setSyncStatus(conn.id, null, e.message);
      return SimpleFinSyncResult(failure: e.message);
    }
  }

  /// Sets the linked entity's balance from the feed and imports transactions
  /// it has not seen. Anything that is really an entry already typed in by
  /// hand is claimed instead of added again.
  Future<({int imported, int matched, List<int> ids})> _applyFeedAccount({
    required int profileId,
    required SimpleFinFeedAccount feed,
    required List<SimpleFinTransaction> transactions,
  }) async {
    const none = (imported: 0, matched: 0, ids: <int>[]);
    final targetId = feed.targetId;
    if (targetId == null) return none;

    return _db.transaction(() async {
      // Balances. Liabilities arrive negative (owed), and Clearly stores the
      // amount owed as a positive number.
      switch (feed.target) {
        case FeedTarget.account:
          await (_db.update(_db.accounts)..where(
                (a) => a.profileId.equals(profileId) & a.id.equals(targetId),
              ))
              .write(AccountsCompanion(balanceCents: Value(feed.balanceCents)));
        case FeedTarget.card:
          await (_db.update(_db.creditCards)..where(
                (c) => c.profileId.equals(profileId) & c.id.equals(targetId),
              ))
              .write(
                CreditCardsCompanion(balanceCents: Value(-feed.balanceCents)),
              );
        case FeedTarget.loan:
          await (_db.update(_db.loans)..where(
                (l) => l.profileId.equals(profileId) & l.id.equals(targetId),
              ))
              .write(LoansCompanion(balanceCents: Value(-feed.balanceCents)));
        case FeedTarget.unmapped:
        case FeedTarget.ignored:
          return none;
      }

      // Loans carry no per-transaction register in Clearly (payments are
      // logged as payments), so only their balance follows the feed.
      if (feed.target == FeedTarget.loan) return none;

      final posted = transactions.where((t) => !t.pending).toList();
      if (posted.isEmpty) return none;
      final known =
          (await (_db.selectOnly(_db.budgetEntries)
                    ..addColumns([_db.budgetEntries.externalId])
                    ..where(
                      _db.budgetEntries.profileId.equals(profileId) &
                          _db.budgetEntries.externalId.like(
                            '${feed.remoteId}:%',
                          ),
                    ))
                  .get())
              .map((r) => r.read(_db.budgetEntries.externalId))
              .toSet();
      // Ones paired into a transfer or payment were not kept as entries,
      // but they have been seen.
      known.addAll(
        (await (_db.select(_db.simpleFinSkipped)..where(
                  (k) =>
                      k.profileId.equals(profileId) &
                      k.externalId.like('${feed.remoteId}:%'),
                ))
                .get())
            .map((k) => k.externalId),
      );
      final fresh = [
        for (final t in posted)
          if (!known.contains('${feed.remoteId}:${t.id}')) t,
      ];
      if (fresh.isEmpty) return none;

      // Entries typed in by hand that are this same transaction: same
      // account, same signed amount, within a few days of when it posted.
      // The bank is the source of truth, so the feed claims them (giving
      // them its id) rather than adding a duplicate beside them.
      final candidates =
          await (_db.select(_db.budgetEntries)..where(
                (e) =>
                    e.profileId.equals(profileId) &
                    e.externalId.isNull() &
                    (feed.target == FeedTarget.account
                        ? e.accountId.equals(targetId)
                        : e.cardId.equals(targetId)),
              ))
              .get();
      final claimed = <int>{};
      final toInsert = <SimpleFinTransaction>[];
      var matched = 0;
      DateTime day(DateTime d) => DateTime.utc(d.year, d.month, d.day);
      fresh.sort((a, b) => a.posted.compareTo(b.posted));
      for (final t in fresh) {
        BudgetEntry? best;
        var bestGap = 4;
        for (final c in candidates) {
          if (claimed.contains(c.id)) continue;
          final signed = c.type == EntryType.income
              ? c.amountCents
              : -c.amountCents;
          if (signed != t.amountCents) continue;
          final gap = day(c.date).difference(day(t.posted)).inDays.abs();
          if (gap < bestGap) {
            best = c;
            bestGap = gap;
          }
        }
        if (best == null) {
          toInsert.add(t);
          continue;
        }
        claimed.add(best.id);
        matched++;
        await (_db.update(
          _db.budgetEntries,
        )..where((e) => e.id.equals(best!.id))).write(
          BudgetEntriesCompanion(externalId: Value('${feed.remoteId}:${t.id}')),
        );
      }
      if (toInsert.isEmpty)
        return (imported: 0, matched: matched, ids: <int>[]);

      final batchId = await _db
          .into(_db.importBatches)
          .insert(
            ImportBatchesCompanion.insert(
              profileId: profileId,
              sourceFilename: 'SimpleFIN: ${feed.name}',
              importedAt: DateTime.now(),
              rowCount: toInsert.length,
              accountId: Value(
                feed.target == FeedTarget.account ? targetId : null,
              ),
              // The balance came from the feed, so undoing this batch must
              // not touch it.
              balanceAdjustmentCents: const Value(0),
            ),
          );
      final insertedIds = <int>[];
      for (final t in toInsert) {
        // The person's own rules first, then the merchant's category code,
        // then nothing.
        final label = t.description.isNotEmpty
            ? t.description
            : (t.payee ?? t.memo ?? '');
        final category =
            await categorize(
              profileId: profileId,
              description: '$label ${t.payee ?? ''} ${t.memo ?? ''}',
              amountCents: t.amountCents,
            ) ??
            categoryForMcc(t.mcc) ??
            'Other';
        final entryId = await _db
            .into(_db.budgetEntries)
            .insert(
              BudgetEntriesCompanion.insert(
                profileId: profileId,
                date: t.posted,
                amountCents: t.amountCents.abs(),
                type: t.amountCents >= 0 ? EntryType.income : EntryType.expense,
                category: Value(category),
                description: Value(label),
                payee: Value(t.payee),
                accountId: Value(
                  feed.target == FeedTarget.account ? targetId : null,
                ),
                cardId: Value(feed.target == FeedTarget.card ? targetId : null),
                importBatchId: Value(batchId),
                externalId: Value('${feed.remoteId}:${t.id}'),
              ),
            );
        insertedIds.add(entryId);
      }
      return (imported: toInsert.length, matched: matched, ids: insertedIds);
    });
  }

  /// Finds money that left one linked account and arrived in another, and
  /// records it as a movement instead of spending plus income.
  ///
  /// A card payment shows up twice in the feeds: as an outflow from the bank
  /// account and as a credit on the card. Left alone, both would land in the
  /// budget (the payment as an expense, the credit as income) and the
  /// purchases on the card would already have been counted. Matching the two
  /// by amount and date and keeping only a payment record fixes that.
  ///
  /// Both entries are removed and remembered in [SimpleFinSkipped] so the
  /// next sync does not import them again. Returns how many pairs were made.
  Future<int> _pairMovements(int profileId, List<int> freshIds) async {
    if (freshIds.isEmpty) return 0;
    final fresh = await (_db.select(
      _db.budgetEntries,
    )..where((e) => e.id.isIn(freshIds))).get();
    // Anything still unpaired from recent syncs can be the other half.
    final since = DateTime.now().subtract(const Duration(days: 14));
    final recent =
        await (_db.select(_db.budgetEntries)..where(
              (e) =>
                  e.profileId.equals(profileId) &
                  e.externalId.isNotNull() &
                  e.date.isBiggerOrEqualValue(since),
            ))
            .get();
    final pool = {
      for (final e in [...recent, ...fresh]) e.id: e,
    }.values.toList();

    DateTime day(DateTime d) => DateTime.utc(d.year, d.month, d.day);
    final used = <int>{};
    var pairs = 0;

    // An outflow from an account, an inflow to a different account or card.
    for (final out in fresh) {
      if (used.contains(out.id) ||
          out.type != EntryType.expense ||
          out.accountId == null) {
        continue;
      }
      BudgetEntry? best;
      var bestGap = 4;
      for (final inn in pool) {
        if (used.contains(inn.id) ||
            inn.id == out.id ||
            inn.type != EntryType.income ||
            inn.amountCents != out.amountCents) {
          continue;
        }
        final intoOther =
            inn.cardId != null ||
            (inn.accountId != null && inn.accountId != out.accountId);
        if (!intoOther) continue;
        final gap = day(inn.date).difference(day(out.date)).inDays.abs();
        if (gap < bestGap) {
          best = inn;
          bestGap = gap;
        }
      }
      if (best == null) continue;
      final inn = best;

      await _db.transaction(() async {
        if (inn.cardId != null) {
          // Paying the card from the account: a payment record, with no
          // balance change since both balances come from the feed.
          await _db
              .into(_db.payments)
              .insert(
                PaymentsCompanion.insert(
                  profileId: profileId,
                  accountType: PaymentAccountType.card,
                  accountId: inn.cardId!,
                  amountCents: out.amountCents,
                  date: out.date,
                  note: const Value('Matched from your bank'),
                  fromAccountId: Value(out.accountId),
                ),
              );
        } else {
          // Account to account: the same record a manual transfer leaves.
          final transferId = await _db
              .into(_db.recurringTransfers)
              .insert(
                RecurringTransfersCompanion.insert(
                  profileId: profileId,
                  name: 'Transfer',
                  fromAccountId: out.accountId!,
                  toAccountId: inn.accountId!,
                  amountCents: out.amountCents,
                  frequency: PayFrequency.monthly,
                  anchorDate: out.date,
                  active: const Value(false),
                ),
              );
          await _db
              .into(_db.transferLogs)
              .insert(
                TransferLogsCompanion.insert(
                  profileId: profileId,
                  transferId: transferId,
                  date: out.date,
                  amountCents: out.amountCents,
                ),
              );
        }
        for (final e in [out, inn]) {
          if (e.externalId != null) {
            await _db
                .into(_db.simpleFinSkipped)
                .insert(
                  SimpleFinSkippedCompanion.insert(
                    profileId: profileId,
                    externalId: e.externalId!,
                  ),
                  mode: InsertMode.insertOrIgnore,
                );
          }
          await (_db.delete(
            _db.budgetEntries,
          )..where((x) => x.id.equals(e.id))).go();
        }
      });
      used
        ..add(out.id)
        ..add(inn.id);
      pairs++;
    }
    return pairs;
  }

  /// Recognises new bank transactions as a bill paid or a paycheck received
  /// that Clearly already knows about, and marks it so. The bank
  /// transaction stays the one entry; the bill or paycheck only records
  /// that it happened, so nothing is counted twice and forecasts stop
  /// expecting it again.
  Future<int> _recognizeRecurring(int profileId, List<int> freshIds) async {
    if (freshIds.isEmpty) return 0;
    final entries = await (_db.select(
      _db.budgetEntries,
    )..where((e) => e.id.isIn(freshIds))).get();
    if (entries.isEmpty) return 0;
    final bills = await (_db.select(
      _db.bills,
    )..where((b) => b.profileId.equals(profileId))).get();
    final paychecks =
        await (_db.select(_db.paychecks)..where(
              (p) => p.profileId.equals(profileId) & p.dismissed.equals(false),
            ))
            .get();

    DateTime day(DateTime d) => DateTime.utc(d.year, d.month, d.day);
    bool nameMatches(String description, String name) {
      final d = description.toLowerCase();
      final words = name
          .toLowerCase()
          .split(RegExp(r'[^a-z0-9]+'))
          .where((w) => w.length >= 4);
      return words.isNotEmpty && words.any(d.contains);
    }

    var count = 0;
    for (final e in entries) {
      final description = e.description ?? '';
      if (e.type == EntryType.expense) {
        Bill? best;
        DateTime? bestPeriod;
        var bestScore = 0;
        for (final b in bills) {
          // A bill is only a candidate for the account or card it is paid
          // from. One with no payment source can match on its name alone.
          final sourceOk =
              b.paymentSourceId == null ||
              (b.paymentSourceType == PaymentSourceType.account &&
                  b.paymentSourceId == e.accountId) ||
              (b.paymentSourceType == PaymentSourceType.card &&
                  b.paymentSourceId == e.cardId);
          if (!sourceOk) continue;
          for (final shift in const [0, -1, 1]) {
            final period = DateTime(e.date.year, e.date.month + shift);
            if (!HomebaseRepository.billFallsIn(b, period)) continue;
            final due = HomebaseRepository.dayInMonth(period.year, period.month, b.dueDay);
            if (day(due).difference(day(e.date)).inDays.abs() > 7) continue;
            final gap = (e.amountCents - b.amountCents).abs();
            final ratio = b.amountCents == 0 ? 1.0 : gap / b.amountCents;
            final name = nameMatches(description, b.name);
            var score = 0;
            if (name) score += 3;
            if (ratio <= 0.02) {
              score += 3;
            } else if (ratio <= 0.25) {
              score += 1;
            }
            if (b.paymentSourceId != null) score += 1;
            // Needs a name, or an essentially exact amount at the expected
            // source; a similar amount on its own is not enough.
            final enough =
                (name && ratio <= 0.6) ||
                (ratio <= 0.02 && b.paymentSourceId != null);
            if (!enough) continue;
            if (score > bestScore) {
              best = b;
              bestPeriod = period;
              bestScore = score;
            }
          }
        }
        if (best == null) continue;
        final alreadyPaid =
            await (_db.select(_db.billPayments)..where(
                  (p) =>
                      p.billId.equals(best!.id) &
                      p.periodStart.equals(bestPeriod!),
                ))
                .getSingleOrNull();
        if (alreadyPaid != null) continue;
        await _db
            .into(_db.billPayments)
            .insert(
              BillPaymentsCompanion.insert(
                profileId: profileId,
                billId: best.id,
                periodStart: bestPeriod!,
                paidAt: e.date,
              ),
              onConflict: DoNothing(),
            );
        if (e.category == 'Other') {
          await (_db.update(_db.budgetEntries)..where((x) => x.id.equals(e.id)))
              .write(BudgetEntriesCompanion(category: Value(best.category)));
        }
        count++;
      } else {
        Paycheck? best;
        var bestGap = 6;
        for (final p in paychecks) {
          if (p.received && p.receivedIsManual) continue;
          if (p.accountId != null && p.accountId != e.accountId) continue;
          final total = p.amountCents + p.bonusCents;
          if ((e.amountCents - total).abs() >
              (total * 0.03).round().clamp(500, 1 << 40)) {
            continue;
          }
          final gap = day(p.date).difference(day(e.date)).inDays.abs();
          if (gap < bestGap) {
            best = p;
            bestGap = gap;
          }
        }
        if (best == null) continue;
        if (!best.received) {
          await (_db.update(_db.paychecks)..where((x) => x.id.equals(best!.id)))
              .write(const PaychecksCompanion(received: Value(true)));
        }
        if (e.category == 'Other') {
          await (_db.update(_db.budgetEntries)..where((x) => x.id.equals(e.id)))
              .write(const BudgetEntriesCompanion(category: Value('Paycheck')));
        }
        count++;
      }
    }
    return count;
  }

  /// Fills in days the app never saw. The feed gives today's balance and
  /// the transactions since, so each earlier day's balance is today's minus
  /// everything that posted after it. That lets the net worth chart and the
  /// account sparklines cover the whole window straight away instead of
  /// growing one day per launch.
  ///
  /// Only days with no snapshot are written, so real recorded points are
  /// never replaced. Accounts that are not linked to the feed are held at
  /// their current balance for those days, which is an approximation.
  Future<void> _backfillHistory({
    required int profileId,
    required List<SimpleFinFeedAccount> feed,
    required Map<String, Map<String, SimpleFinTransaction>> transactions,
    required DateTime start,
    required DateTime now,
  }) async {
    final today = DateTime(now.year, now.month, now.day);
    final days = <DateTime>[];
    for (
      var d = DateTime(start.year, start.month, start.day);
      d.isBefore(today);
      d = DateTime(d.year, d.month, d.day + 1)
    ) {
      days.add(d);
    }
    if (days.isEmpty) return;

    // Amount owed or held at the end of each day, for each linked target.
    final history = <(FeedTarget, int), Map<DateTime, int>>{};
    for (final f in feed) {
      final id = f.targetId;
      if (id == null ||
          (f.target != FeedTarget.account &&
              f.target != FeedTarget.card &&
              f.target != FeedTarget.loan)) {
        continue;
      }
      final txns = (transactions[f.remoteId] ?? {}).values
          .where((t) => !t.pending)
          .toList();
      final byDay = <DateTime, int>{};
      for (final d in days) {
        final after = txns
            .where((t) => t.posted.isAfter(d))
            .fold(0, (sum, t) => sum + t.amountCents);
        final feedBalance = f.balanceCents - after;
        // Liabilities are negative in the feed; Clearly stores amount owed.
        byDay[d] = f.target == FeedTarget.account ? feedBalance : -feedBalance;
      }
      history[(f.target, id)] = byDay;
    }
    if (history.isEmpty) return;

    final accounts = await (_db.select(
      _db.accounts,
    )..where((a) => a.profileId.equals(profileId))).get();
    final cards = await (_db.select(
      _db.creditCards,
    )..where((c) => c.profileId.equals(profileId))).get();
    final loans = await (_db.select(
      _db.loans,
    )..where((l) => l.profileId.equals(profileId))).get();

    await _db.transaction(() async {
      for (final d in days) {
        var assets = 0;
        var debts = 0;
        for (final a in accounts) {
          final b = history[(FeedTarget.account, a.id)]?[d] ?? a.balanceCents;
          assets += b;
          if (history.containsKey((FeedTarget.account, a.id))) {
            await _db
                .into(_db.accountBalanceSnapshots)
                .insert(
                  AccountBalanceSnapshotsCompanion.insert(
                    profileId: profileId,
                    accountId: a.id,
                    date: d,
                    balanceCents: b,
                  ),
                  mode: InsertMode.insertOrIgnore,
                );
          }
        }
        for (final c in cards) {
          debts += history[(FeedTarget.card, c.id)]?[d] ?? c.balanceCents;
        }
        for (final l in loans) {
          debts += history[(FeedTarget.loan, l.id)]?[d] ?? l.balanceCents;
        }
        await _db
            .into(_db.netWorthSnapshots)
            .insert(
              NetWorthSnapshotsCompanion.insert(
                profileId: profileId,
                date: d,
                totalAssetsCents: assets,
                totalDebtCents: debts,
                netWorthCents: assets - debts,
              ),
              mode: InsertMode.insertOrIgnore,
            );
      }
    });
  }

  /// Whether the bank feed owns this account, card or loan's balance. A
  /// linked balance is not editable by hand: the next sync would overwrite
  /// it anyway.
  Future<bool> isSimpleFinLinked(FeedTarget target, int id) async {
    final row =
        await (_db.select(_db.simpleFinFeedAccounts)..where(
              (f) => f.target.equalsValue(target) & f.targetId.equals(id),
            ))
            .getSingleOrNull();
    return row != null;
  }

  Future<void> _upsertFeedAccounts(
    int connectionId,
    List<SimpleFinAccount> accounts,
  ) async {
    for (final a in accounts) {
      final existing =
          await (_db.select(_db.simpleFinFeedAccounts)..where(
                (f) =>
                    f.connectionId.equals(connectionId) &
                    f.remoteId.equals(a.id),
              ))
              .getSingleOrNull();
      if (existing == null) {
        await _db
            .into(_db.simpleFinFeedAccounts)
            .insert(
              SimpleFinFeedAccountsCompanion.insert(
                connectionId: connectionId,
                remoteId: a.id,
                name: a.name,
                orgName: Value(a.orgName),
                balanceCents: Value(a.balanceCents),
                balanceDate: Value(a.balanceDate),
              ),
            );
      } else {
        await (_db.update(
          _db.simpleFinFeedAccounts,
        )..where((f) => f.id.equals(existing.id))).write(
          SimpleFinFeedAccountsCompanion(
            name: Value(a.name),
            orgName: Value(a.orgName),
            balanceCents: Value(a.balanceCents),
            balanceDate: Value(a.balanceDate),
          ),
        );
      }
    }
  }

  Future<void> _setSyncStatus(int connectionId, DateTime? at, String message) =>
      (_db.update(
        _db.simpleFinConnections,
      )..where((c) => c.id.equals(connectionId))).write(
        SimpleFinConnectionsCompanion(
          lastSyncAt: at == null ? const Value.absent() : Value(at),
          lastSyncMessage: Value(message),
        ),
      );

  /// Links a feed account to an existing account or card. A target can be
  /// linked from only one feed account, since two feeds writing one balance
  /// would fight.
  Future<void> linkSimpleFinAccount({
    required int profileId,
    required int feedAccountId,
    required FeedTarget target,
    required int targetId,
  }) async {
    assert(
      target == FeedTarget.account ||
          target == FeedTarget.card ||
          target == FeedTarget.loan,
    );
    final taken =
        await (_db.select(_db.simpleFinFeedAccounts)..where(
              (f) =>
                  f.target.equalsValue(target) &
                  f.targetId.equals(targetId) &
                  f.id.isNotValue(feedAccountId),
            ))
            .getSingleOrNull();
    if (taken != null) {
      throw StateError('That is already linked to "${taken.name}".');
    }
    await (_db.update(
      _db.simpleFinFeedAccounts,
    )..where((f) => f.id.equals(feedAccountId))).write(
      SimpleFinFeedAccountsCompanion(
        target: Value(target),
        targetId: Value(targetId),
      ),
    );
  }

  /// Creates an account, card or loan from a feed account's name and
  /// balance, links it, and returns its id.
  Future<int> createFromSimpleFinAccount({
    required int profileId,
    required int feedAccountId,
    required FeedTarget kind,
    AccountType accountType = AccountType.checking,
  }) async {
    final feed = await (_db.select(
      _db.simpleFinFeedAccounts,
    )..where((f) => f.id.equals(feedAccountId))).getSingle();
    final int id;
    switch (kind) {
      case FeedTarget.account:
        id = await upsertAccount(
          AccountsCompanion.insert(
            profileId: profileId,
            name: feed.name,
            institution: Value(feed.orgName),
            type: accountType,
            balanceCents: Value(feed.balanceCents),
          ),
        );
      case FeedTarget.card:
        id = await upsertCard(
          CreditCardsCompanion.insert(
            profileId: profileId,
            name: feed.name,
            balanceCents: Value(-feed.balanceCents),
            creditLimitCents: 0,
          ),
        );
      case FeedTarget.loan:
        id = await upsertLoan(
          LoansCompanion.insert(
            profileId: profileId,
            name: feed.name,
            balanceCents: -feed.balanceCents,
            originalAmountCents: -feed.balanceCents,
          ),
        );
      case FeedTarget.unmapped:
      case FeedTarget.ignored:
        throw ArgumentError('Pick an account, card or loan.');
    }
    await linkSimpleFinAccount(
      profileId: profileId,
      feedAccountId: feedAccountId,
      target: kind,
      targetId: id,
    );
    return id;
  }

  Future<void> ignoreSimpleFinAccount(int feedAccountId) =>
      (_db.update(
        _db.simpleFinFeedAccounts,
      )..where((f) => f.id.equals(feedAccountId))).write(
        const SimpleFinFeedAccountsCompanion(
          target: Value(FeedTarget.ignored),
          targetId: Value(null),
        ),
      );

  /// Back to the review list.
  Future<void> unlinkSimpleFinAccount(int feedAccountId) =>
      (_db.update(
        _db.simpleFinFeedAccounts,
      )..where((f) => f.id.equals(feedAccountId))).write(
        const SimpleFinFeedAccountsCompanion(
          target: Value(FeedTarget.unmapped),
          targetId: Value(null),
        ),
      );

  /// Drops the connection and its feed list. Imported entries and the
  /// accounts they landed in are left alone.
  Future<void> disconnectSimpleFin({
    required int profileId,
    required int connectionId,
  }) =>
      (_db.delete(_db.simpleFinConnections)..where(
            (c) => c.profileId.equals(profileId) & c.id.equals(connectionId),
          ))
          .go();

  /// A deleted account, card or loan must not stay a sync target.
  Future<void> _clearFeedLinks(FeedTarget target, int id) =>
      (_db.update(
            _db.simpleFinFeedAccounts,
          )..where((f) => f.target.equalsValue(target) & f.targetId.equals(id)))
          .write(
            const SimpleFinFeedAccountsCompanion(
              target: Value(FeedTarget.unmapped),
              targetId: Value(null),
            ),
          );
}
