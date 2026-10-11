part of 'repository.dart';

/// What one sync did, for showing to the person.
class SimpleFinSyncResult {
  const SimpleFinSyncResult({
    this.newTransactions = 0,
    this.syncedAccounts = 0,
    this.unmappedAccounts = 0,
    this.messages = const [],
    this.failure,
  });

  /// Transactions imported this time (already-seen ones are not counted).
  final int newTransactions;

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
      var synced = 0;
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
            imported += await _applyFeedAccount(
              profileId: conn.profileId,
              feed: f,
              transactions: (transactions[f.remoteId] ?? {}).values.toList(),
            );
        }
      }

      final parts = <String>[
        if (imported > 0) '$imported new' else 'Up to date',
        if (unmapped > 0) '$unmapped to review',
        ...messages,
      ];
      await _setSyncStatus(conn.id, now, parts.join('; '));
      return SimpleFinSyncResult(
        newTransactions: imported,
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
  /// it has not seen. Returns how many were imported.
  Future<int> _applyFeedAccount({
    required int profileId,
    required SimpleFinFeedAccount feed,
    required List<SimpleFinTransaction> transactions,
  }) async {
    final targetId = feed.targetId;
    if (targetId == null) return 0;

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
          return 0;
      }

      // Loans carry no per-transaction register in Clearly (payments are
      // logged as payments), so only their balance follows the feed.
      if (feed.target == FeedTarget.loan) return 0;

      final posted = transactions.where((t) => !t.pending).toList();
      if (posted.isEmpty) return 0;
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
      final fresh = [
        for (final t in posted)
          if (!known.contains('${feed.remoteId}:${t.id}')) t,
      ];
      if (fresh.isEmpty) return 0;

      final batchId = await _db
          .into(_db.importBatches)
          .insert(
            ImportBatchesCompanion.insert(
              profileId: profileId,
              sourceFilename: 'SimpleFIN: ${feed.name}',
              importedAt: DateTime.now(),
              rowCount: fresh.length,
              accountId: Value(
                feed.target == FeedTarget.account ? targetId : null,
              ),
              // The balance came from the feed, so undoing this batch must
              // not touch it.
              balanceAdjustmentCents: const Value(0),
            ),
          );
      for (final t in fresh) {
        final category =
            await categorize(
              profileId: profileId,
              description: t.description,
              amountCents: t.amountCents,
            ) ??
            'Other';
        await _db
            .into(_db.budgetEntries)
            .insert(
              BudgetEntriesCompanion.insert(
                profileId: profileId,
                date: t.posted,
                amountCents: t.amountCents.abs(),
                type: t.amountCents >= 0 ? EntryType.income : EntryType.expense,
                category: Value(category),
                description: Value(t.description),
                accountId: Value(
                  feed.target == FeedTarget.account ? targetId : null,
                ),
                cardId: Value(feed.target == FeedTarget.card ? targetId : null),
                importBatchId: Value(batchId),
                externalId: Value('${feed.remoteId}:${t.id}'),
              ),
            );
      }
      return fresh.length;
    });
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
