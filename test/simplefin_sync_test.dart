import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';
import 'package:clearly/data/simplefin.dart';
import 'package:clearly/data/transaction_draft.dart';

/// A scripted Bridge: claim returns an access url, /accounts returns
/// whatever [accounts] currently holds.
class FakeBridge implements SimpleFinTransport {
  List<Map<String, Object?>> accounts = [];
  List<Map<String, Object?>> errlist = [];
  int status = 200;
  final fetches = <Uri>[];

  @override
  Future<({int status, String body})> send(String method, Uri url,
      {Map<String, String> headers = const {}}) async {
    if (method == 'POST') {
      return (status: 200, body: 'https://u:p@bridge.test/simplefin');
    }
    fetches.add(url);
    if (status != 200) return (status: status, body: '');
    return (
      status: 200,
      body: jsonEncode({'errlist': errlist, 'accounts': accounts}),
    );
  }
}

String token() =>
    base64.encode(utf8.encode('https://bridge.test/simplefin/claim/X'));

int epoch(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;

void main() {
  late AppDatabase db;
  late HomebaseRepository repo;
  late FakeBridge bridge;
  late SimpleFinClient client;
  late int profileId;
  final now = DateTime(2026, 6, 15, 12);

  Map<String, Object?> txn(String id, String amount, String desc,
          {DateTime? posted, bool pending = false}) =>
      {
        'id': id,
        'posted': epoch(posted ?? DateTime(2026, 6, 10)),
        'amount': amount,
        'description': desc,
        if (pending) 'pending': true,
      };

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = HomebaseRepository(db);
    bridge = FakeBridge();
    client = SimpleFinClient(transport: bridge);
    profileId = await repo.createProfile(
        ProfilesCompanion.insert(name: 'Owner', isAdmin: const Value(true)));
    bridge.accounts = [
      {
        'id': 'CHK',
        'name': 'Everyday',
        'balance': '1500.00',
        'balance-date': epoch(DateTime(2026, 6, 14)),
        'org': {'name': 'Example Bank'},
        'transactions': [
          txn('a', '-4.50', 'COFFEE'),
          txn('b', '2000.00', 'PAYROLL'),
          txn('p', '-9.99', 'PENDING THING', pending: true),
        ],
      },
      {
        'id': 'CC',
        'name': 'Visa',
        'balance': '-320.40',
        'transactions': [txn('c1', '-20.00', 'GROCERY')],
      },
      {'id': 'LN', 'name': 'Car loan', 'balance': '-8000.00', 'transactions': []},
    ];
  });
  tearDown(() => db.close());

  Future<List<SimpleFinFeedAccount>> feed() =>
      repo.watchSimpleFinFeedAccounts(profileId: profileId).first;

  test('connecting lists the feed accounts as unmapped and imports nothing',
      () async {
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    final f = await feed();
    expect(f.map((a) => a.name), containsAll(['Everyday', 'Visa', 'Car loan']));
    expect(f.every((a) => a.target == FeedTarget.unmapped), isTrue);
    expect(await db.select(db.budgetEntries).get(), isEmpty);
    expect(bridge.fetches.single.queryParameters['balances-only'], '1');
  });

  test('creating from the feed links it, sets balances and imports once',
      () async {
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    final f = await feed();
    int idOf(String name) => f.firstWhere((a) => a.name == name).id;

    await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: idOf('Everyday'),
        kind: FeedTarget.account);
    await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: idOf('Visa'),
        kind: FeedTarget.card);
    await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: idOf('Car loan'),
        kind: FeedTarget.loan);

    final result = await repo.syncSimpleFin(
        profileId: profileId, client: client, now: now);
    expect(result.newTransactions, 3, reason: 'pending is not imported');
    expect(result.syncedAccounts, 3);
    expect(result.failure, isNull);

    final account = (await db.select(db.accounts).get()).single;
    expect(account.balanceCents, 150000);
    expect(account.institution, 'Example Bank');
    final card = (await db.select(db.creditCards).get()).single;
    expect(card.balanceCents, 32040, reason: 'owed is stored positive');
    final loan = (await db.select(db.loans).get()).single;
    expect(loan.balanceCents, 800000);

    final entries = await db.select(db.budgetEntries).get();
    expect(entries, hasLength(3));
    final coffee = entries.firstWhere((e) => e.description == 'COFFEE');
    expect(coffee.type, EntryType.expense);
    expect(coffee.amountCents, 450);
    expect(coffee.accountId, account.id);
    expect(coffee.externalId, 'CHK:a');
    expect(entries.firstWhere((e) => e.description == 'PAYROLL').type,
        EntryType.income);
    expect(entries.firstWhere((e) => e.description == 'GROCERY').cardId,
        card.id);

    // Running it again over the same window adds nothing.
    final again = await repo.syncSimpleFin(
        profileId: profileId, client: client, now: now.add(const Duration(hours: 1)));
    expect(again.newTransactions, 0);
    expect(await db.select(db.budgetEntries).get(), hasLength(3));
  });

  test('a later sync picks up only the new transaction', () async {
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    final f = await feed();
    await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: f.firstWhere((a) => a.name == 'Everyday').id,
        kind: FeedTarget.account);
    await repo.syncSimpleFin(profileId: profileId, client: client, now: now);

    (bridge.accounts.first['transactions'] as List).add(
        txn('d', '-30.00', 'GAS', posted: DateTime(2026, 6, 15)));
    bridge.accounts.first['balance'] = '1465.50';
    final r = await repo.syncSimpleFin(
        profileId: profileId,
        client: client,
        now: now.add(const Duration(days: 1)));
    expect(r.newTransactions, 1);
    expect((await db.select(db.accounts).get()).single.balanceCents, 146550);
  });

  test('unmapped and ignored accounts import nothing', () async {
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    final f = await feed();
    await repo.ignoreSimpleFinAccount(f.first.id);
    final r = await repo.syncSimpleFin(
        profileId: profileId, client: client, now: now);
    expect(r.newTransactions, 0);
    expect(r.unmappedAccounts, 2);
    expect(await db.select(db.budgetEntries).get(), isEmpty);
    expect(await db.select(db.accounts).get(), isEmpty);
  });

  test('the sync is undoable as a batch, without touching the balance',
      () async {
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    final f = await feed();
    await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: f.firstWhere((a) => a.name == 'Everyday').id,
        kind: FeedTarget.account);
    await repo.syncSimpleFin(profileId: profileId, client: client, now: now);

    final batch = (await db.select(db.importBatches).get()).single;
    expect(batch.balanceAdjustmentCents, 0);
    await repo.undoImportBatch(profileId: profileId, batchId: batch.id);
    expect(await db.select(db.budgetEntries).get(), isEmpty);
    expect((await db.select(db.accounts).get()).single.balanceCents, 150000);
  });

  test('a target can only be linked from one feed account', () async {
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    final f = await feed();
    final acc = await repo.upsertAccount(AccountsCompanion.insert(
        profileId: profileId, name: 'Mine', type: AccountType.checking));
    await repo.linkSimpleFinAccount(
        profileId: profileId,
        feedAccountId: f[0].id,
        target: FeedTarget.account,
        targetId: acc);
    expect(
        () => repo.linkSimpleFinAccount(
            profileId: profileId,
            feedAccountId: f[1].id,
            target: FeedTarget.account,
            targetId: acc),
        throwsStateError);
  });

  test('deleting a linked account sends its feed account back to review',
      () async {
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    final f = await feed();
    final id = await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: f.firstWhere((a) => a.name == 'Everyday').id,
        kind: FeedTarget.account);
    await repo.deleteAccount(profileId: profileId, id: id);
    final after = (await feed()).firstWhere((a) => a.name == 'Everyday');
    expect(after.target, FeedTarget.unmapped);
    expect(after.targetId, isNull);
  });

  test('bridge errors are returned and a failed fetch is reported, not thrown',
      () async {
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    bridge.errlist = [
      {'code': 'gen.auth', 'msg': 'Sign in again at Example Bank'}
    ];
    var r = await repo.syncSimpleFin(
        profileId: profileId, client: client, now: now);
    expect(r.messages, contains('Sign in again at Example Bank'));

    bridge.status = 403;
    r = await repo.syncSimpleFin(profileId: profileId, client: client, now: now);
    expect(r.failure, isNotNull);
    final conn = (await db.select(db.simpleFinConnections).get()).single;
    expect(conn.lastSyncMessage, contains('connect again'));
  });

  test('a long gap is read in windows of at most 90 days', () async {
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    bridge.fetches.clear();
    await repo.syncSimpleFin(
        profileId: profileId,
        client: client,
        now: now,
        lookback: const Duration(days: 200));
    expect(bridge.fetches, hasLength(3));
    for (final u in bridge.fetches) {
      final s = int.parse(u.queryParameters['start-date']!);
      final e = int.parse(u.queryParameters['end-date']!);
      expect(e - s, lessThanOrEqualTo(90 * 86400));
    }
  });

  test('disconnecting keeps the accounts and imported entries', () async {
    final conn = await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    final f = await feed();
    await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: f.firstWhere((a) => a.name == 'Everyday').id,
        kind: FeedTarget.account);
    await repo.syncSimpleFin(profileId: profileId, client: client, now: now);
    await repo.disconnectSimpleFin(profileId: profileId, connectionId: conn);
    expect(await feed(), isEmpty);
    expect(await db.select(db.accounts).get(), hasLength(1));
    expect(await db.select(db.budgetEntries).get(), hasLength(2));
  });

  test('an entry typed in by hand is claimed by its bank transaction, not '
      'duplicated', () async {
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    final f = await feed();
    final accountId = await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: f.firstWhere((a) => a.name == 'Everyday').id,
        kind: FeedTarget.account);
    // The person already logged the coffee, a day off from the bank's date.
    await db.into(db.budgetEntries).insert(BudgetEntriesCompanion.insert(
        profileId: profileId,
        date: DateTime(2026, 6, 9),
        amountCents: 450,
        type: EntryType.expense,
        description: const Value('coffee'),
        accountId: Value(accountId)));

    final r = await repo.syncSimpleFin(
        profileId: profileId, client: client, now: now);
    expect(r.matchedTransactions, 1);
    expect(r.newTransactions, 1, reason: 'only the payroll is new');

    final entries = await db.select(db.budgetEntries).get();
    expect(entries, hasLength(2));
    final coffee = entries.firstWhere((e) => e.description == 'coffee');
    expect(coffee.externalId, 'CHK:a', reason: 'claimed by the feed id');

    // Running again finds it known and adds nothing.
    final again = await repo.syncSimpleFin(
        profileId: profileId, client: client, now: now);
    expect(again.newTransactions + again.matchedTransactions, 0);
  });

  test('the first sync rebuilds daily balances from the transactions',
      () async {
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    final f = await feed();
    final accountId = await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: f.firstWhere((a) => a.name == 'Everyday').id,
        kind: FeedTarget.account);
    await repo.syncSimpleFin(
        profileId: profileId,
        client: client,
        now: now,
        lookback: const Duration(days: 30));

    // Balance today is 1500.00. Payroll (+2000) and coffee (-4.50) posted
    // on Jun 10, so before that day the balance was 1500 - 2000 + 4.50.
    final snaps = await (db.select(db.accountBalanceSnapshots)
          ..where((s) => s.accountId.equals(accountId)))
        .get();
    int on(DateTime d) => snaps
        .firstWhere((s) =>
            s.date.year == d.year && s.date.month == d.month && s.date.day == d.day)
        .balanceCents;
    expect(on(DateTime(2026, 6, 9)), 150000 - 200000 + 450);
    expect(on(DateTime(2026, 6, 10)), 150000, reason: 'end of the posting day');
    expect(on(DateTime(2026, 6, 14)), 150000);

    // Net worth history exists for those days too, so the chart has a line.
    final nw = await db.select(db.netWorthSnapshots).get();
    expect(nw.length, greaterThan(20));
  });

  test('a linked account balance cannot be edited by hand', () async {
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    final f = await feed();
    final id = await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: f.firstWhere((a) => a.name == 'Everyday').id,
        kind: FeedTarget.account);
    expect(await repo.isSimpleFinLinked(FeedTarget.account, id), isTrue);

    await repo.upsertAccount(AccountsCompanion(
        id: Value(id),
        profileId: Value(profileId),
        name: const Value('Renamed'),
        type: const Value(AccountType.savings),
        balanceCents: const Value(1)));
    final a = (await db.select(db.accounts).get()).single;
    expect(a.name, 'Renamed', reason: 'other fields still edit');
    expect(a.balanceCents, 150000, reason: 'the bank owns the balance');
  });

  group('real-world patterns', () {
    test('entries imported earlier are tidied: transfer, card payments, and '
        'a card credit paid from an unlinked account', () async {
      // Imported as plain entries first, the way they were before pairing
      // existed.
      bridge.accounts = [
        {
          'id': 'CHK',
          'name': 'TOTAL CHECKING (8841)',
          'balance': '125.00',
          'transactions': [
            txn('x1', '-510.00', 'AMERICANEXPRESS TRANSFER 000320048988169 WEB ID: 1',
                posted: DateTime(2026, 6, 6)),
            txn('x2', '-100.00', 'Payment to Chase card ending in 0857 10/08',
                posted: DateTime(2026, 6, 8)),
            txn('x3', '-50.00', 'AMERICAN EXPRESS ACH PMT M3724 WEB ID: 2',
                posted: DateTime(2026, 6, 8)),
            txn('x4', '-5.00', 'COFFEE', posted: DateTime(2026, 6, 8)),
          ],
        },
        {
          'id': 'SAV',
          'name': 'High Yield Savings Account (8169)',
          'balance': '1749.66',
          'transactions': [
            txn('s1', '510.00',
                'Internet transfer from JPMORGAN CHASE BANK, NA DDA account XXXXX8841',
                posted: DateTime(2026, 6, 5)),
            txn('s2', '50.00',
                'Internet transfer from JPMORGAN CHASE BANK, NA DDA account XXXXX8841',
                posted: DateTime(2026, 6, 9)),
          ],
        },
        {
          'id': 'CHASE',
          'name': 'Chase Freedom Unlimited (0857)',
          'balance': '-493.26',
          'transactions': [
            txn('c1', '100.00', 'Payment Thank You-Mobile',
                posted: DateTime(2026, 6, 8)),
          ],
        },
        {
          'id': 'DELTA',
          'name': 'Delta SkyMiles Gold Card (1006)',
          'balance': '-343.10',
          'transactions': [
            // Paid from an account that is not linked, so no outflow exists.
            txn('d1', '140.24', 'MOBILE PAYMENT - THANK YOU',
                posted: DateTime(2026, 6, 8)),
            txn('d2', '50.00', 'MOBILE PAYMENT - THANK YOU',
                posted: DateTime(2026, 6, 8)),
            txn('d3', '-12.00', 'GAS STATION', posted: DateTime(2026, 6, 7)),
          ],
        },
      ];
      await repo.connectSimpleFin(
          profileId: profileId, setupToken: token(), client: client, now: now);
      for (final a in await feed()) {
        await repo.createFromSimpleFinAccount(
          profileId: profileId,
          feedAccountId: a.id,
          kind: a.name.startsWith('Chase') || a.name.startsWith('Delta')
              ? FeedTarget.card
              : FeedTarget.account,
        );
      }

      final r = await repo.syncSimpleFin(
          profileId: profileId, client: client, now: now);
      expect(r.pairedMovements, greaterThanOrEqualTo(5));

      final left = await db.select(db.budgetEntries).get();
      expect(left.map((e) => e.description).toSet(),
          {'COFFEE', 'GAS STATION'},
          reason: 'only real spending is left; nothing counted as income');
      expect(left.where((e) => e.type == EntryType.income), isEmpty);

      // The $510 moved from checking to savings, not income.
      final logs = await db.select(db.transferLogs).get();
      expect(logs.where((l) => l.amountCents == 51000), hasLength(1));

      // Card payments are recorded, with a source when one is known.
      final payments = await db.select(db.payments).get();
      expect(payments.where((p) => p.amountCents == 10000), hasLength(1));
      expect(payments.firstWhere((p) => p.amountCents == 10000).fromAccountId,
          isNotNull);
      expect(payments.firstWhere((p) => p.amountCents == 14024).fromAccountId,
          isNull,
          reason: 'paid from an account Clearly does not know');

      // And the next sync leaves everything as it is.
      final again = await repo.syncSimpleFin(
          profileId: profileId, client: client, now: now);
      expect(again.newTransactions, 0);
      expect(await db.select(db.budgetEntries).get(), hasLength(2));
      expect(await db.select(db.payments).get(), hasLength(payments.length));
    });
  });

  group('with Clearly Sync on', () {
    Future<void> linkAll() async {
      await repo.connectSimpleFin(
          profileId: profileId, setupToken: token(), client: client, now: now);
      for (final a in await feed()) {
        await repo.createFromSimpleFinAccount(
          profileId: profileId,
          feedAccountId: a.id,
          kind: a.name == 'Visa' ? FeedTarget.card : FeedTarget.account,
        );
      }
    }

    test('a card payment is one movement, not an expense plus income',
        () async {
      bridge.accounts = [
        {
          'id': 'CHK',
          'name': 'Everyday',
          'balance': '900.00',
          'transactions': [
            txn('pay', '-100.00', 'VISA PAYMENT', posted: DateTime(2026, 6, 12)),
          ],
        },
        {
          'id': 'CC',
          'name': 'Visa',
          'balance': '-200.00',
          'transactions': [
            txn('c1', '-40.00', 'GROCERY', posted: DateTime(2026, 6, 8)),
            txn('credit', '100.00', 'PAYMENT THANK YOU',
                posted: DateTime(2026, 6, 13)),
          ],
        },
      ];
      await linkAll();
      final r = await repo.syncSimpleFin(
          profileId: profileId, client: client, now: now);
      expect(r.pairedMovements, 1);

      final entries = await db.select(db.budgetEntries).get();
      expect(entries.map((e) => e.description), ['GROCERY'],
          reason: 'only the real purchase is spending');
      final payment = (await db.select(db.payments).get()).single;
      expect(payment.amountCents, 10000);
      expect(payment.accountType, PaymentAccountType.card);
      expect(payment.fromAccountId, isNotNull);

      // Balances still come straight from the feed.
      expect((await db.select(db.creditCards).get()).single.balanceCents,
          20000);

      // And they are not imported again on the next sync.
      final again = await repo.syncSimpleFin(
          profileId: profileId, client: client, now: now);
      expect(again.newTransactions, 0);
      expect(await db.select(db.budgetEntries).get(), hasLength(1));
      expect(await db.select(db.payments).get(), hasLength(1));
    });

    test('a transfer between two linked accounts becomes a transfer record',
        () async {
      bridge.accounts = [
        {
          'id': 'CHK',
          'name': 'Everyday',
          'balance': '400.00',
          'transactions': [
            txn('out', '-250.00', 'TO SAVINGS', posted: DateTime(2026, 6, 11)),
          ],
        },
        {
          'id': 'SAV',
          'name': 'Savings',
          'balance': '1250.00',
          'transactions': [
            txn('in', '250.00', 'FROM CHECKING', posted: DateTime(2026, 6, 11)),
          ],
        },
      ];
      await linkAll();
      final r = await repo.syncSimpleFin(
          profileId: profileId, client: client, now: now);
      expect(r.pairedMovements, 1);
      expect(await db.select(db.budgetEntries).get(), isEmpty);
      final log = (await db.select(db.transferLogs).get()).single;
      expect(log.amountCents, 25000);
      // Both balances are still the bank's.
      final balances = (await db.select(db.accounts).get())
          .map((a) => a.balanceCents)
          .toSet();
      expect(balances, {40000, 125000});
    });

    test('unlike amounts are never paired', () async {
      bridge.accounts = [
        {
          'id': 'CHK',
          'name': 'Everyday',
          'balance': '900.00',
          'transactions': [txn('o', '-100.00', 'STORE')],
        },
        {
          'id': 'SAV',
          'name': 'Savings',
          'balance': '10.00',
          'transactions': [txn('i', '99.00', 'INTEREST')],
        },
      ];
      await linkAll();
      final r = await repo.syncSimpleFin(
          profileId: profileId, client: client, now: now);
      expect(r.pairedMovements, 0);
      expect(await db.select(db.budgetEntries).get(), hasLength(2));
    });

    test('a bank transaction marks the bill paid and the paycheck received',
        () async {
      bridge.accounts = [
        {
          'id': 'CHK',
          'name': 'Everyday',
          'balance': '1000.00',
          'transactions': [
            txn('b', '-94.00', 'METROPCS WIRELESS', posted: DateTime(2026, 6, 10)),
            txn('p', '750.00', 'ACME PAYROLL', posted: DateTime(2026, 6, 12)),
          ],
        },
      ];
      await repo.connectSimpleFin(
          profileId: profileId, setupToken: token(), client: client, now: now);
      final accountId = await repo.createFromSimpleFinAccount(
          profileId: profileId,
          feedAccountId: (await feed()).single.id,
          kind: FeedTarget.account);
      final billId = await repo.upsertBill(BillsCompanion.insert(
        profileId: profileId,
        name: 'MetroPCS',
        amountCents: 9400,
        dueDay: 10,
        category: const Value('Utilities'),
        paymentSourceType: const Value(PaymentSourceType.account),
        paymentSourceId: Value(accountId),
      ));
      final paycheckId = await repo.upsertPaycheck(PaychecksCompanion.insert(
        profileId: profileId,
        name: 'Work',
        date: DateTime(2026, 6, 12),
        amountCents: 75000,
        accountId: Value(accountId),
      ));

      final r = await repo.syncSimpleFin(
          profileId: profileId, client: client, now: now);
      expect(r.recognizedRecurring, 2);

      final payments = await db.select(db.billPayments).get();
      expect(payments.single.billId, billId);
      expect(payments.single.periodStart, DateTime(2026, 6));
      final paycheck = await (db.select(db.paychecks)
            ..where((p) => p.id.equals(paycheckId)))
          .getSingle();
      expect(paycheck.received, isTrue);

      // The bank transaction is the entry; nothing was added beside it.
      final entries = await db.select(db.budgetEntries).get();
      expect(entries, hasLength(2));
      expect(entries.firstWhere((e) => e.description!.contains('METRO')).category,
          'Utilities');
      expect(entries.firstWhere((e) => e.description!.contains('PAYROLL')).category,
          'Paycheck');
    });

    test('recurring items do not add their own entries or move balances on '
        'a synced account', () async {
      bridge.accounts = [
        {
          'id': 'CHK',
          'name': 'Everyday',
          'balance': '1000.00',
          'transactions': <Object>[],
        },
      ];
      await repo.connectSimpleFin(
          profileId: profileId, setupToken: token(), client: client, now: now);
      final accountId = await repo.createFromSimpleFinAccount(
          profileId: profileId,
          feedAccountId: (await feed()).single.id,
          kind: FeedTarget.account);

      await repo.upsertBill(BillsCompanion.insert(
        profileId: profileId,
        name: 'Rent',
        amountCents: 50000,
        dueDay: 1,
        autopay: const Value(true),
        paymentSourceType: const Value(PaymentSourceType.account),
        paymentSourceId: Value(accountId),
      ));
      await repo.materializeAutopayPayments(
          profileId: profileId, month: DateTime.now());
      await repo.upsertPaycheck(PaychecksCompanion.insert(
        profileId: profileId,
        name: 'Work',
        date: DateTime(2026, 1, 2),
        amountCents: 100000,
        received: const Value(true),
        accountId: Value(accountId),
      ));
      await repo.addTransaction(
        profileId: profileId,
        draft: TransactionDraft(
          kind: DraftKind.expense,
          amountCents: 700,
          date: DateTime.now(),
          name: 'Coffee',
          accountId: accountId,
        ),
      );

      expect((await db.select(db.accounts).get()).single.balanceCents, 100000,
          reason: 'only the bank moves a synced balance');
      final entries = await db.select(db.budgetEntries).get();
      expect(entries.map((e) => e.description),
          isNot(containsAll(['Rent', 'Work'])),
          reason: 'bill and paycheck mirrors are not created');
    });

    test('deleting a profile with a connection does not fail', () async {
      await repo.connectSimpleFin(
          profileId: profileId, setupToken: token(), client: client, now: now);
      final other = await repo.createProfile(ProfilesCompanion.insert(
          name: 'Other', isAdmin: const Value(false)));
      await repo.connectSimpleFin(
          profileId: other, setupToken: token(), client: client, now: now);
      await repo.deleteProfile(id: other);
      expect(await db.select(db.simpleFinConnections).get(), hasLength(1));
    });
  });

  test('imports keep the payee and categorize by merchant code, with the '
      "person's own rules taking priority", () async {
    bridge.accounts = [
      {
        'id': 'CHK',
        'name': 'Everyday',
        'balance': '100.00',
        'transactions': [
          {
            'id': 'm1',
            'posted': epoch(DateTime(2026, 6, 10)),
            'amount': '-85.50',
            'description': 'Grocery store',
            'payee': 'Local Grocer',
            'memo': 'LOCAL GROCER STORE #1133',
            'mcc': '5411',
          },
          {
            'id': 'm2',
            'posted': epoch(DateTime(2026, 6, 11)),
            'amount': '-12.00',
            'description': 'Lunch',
            'mcc': '5812',
          },
          {
            'id': 'm3',
            'posted': epoch(DateTime(2026, 6, 12)),
            'amount': '-30.00',
            'description': 'Joes Diner',
            'mcc': '5812',
          },
        ],
      },
    ];
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: (await feed()).single.id,
        kind: FeedTarget.account);
    await db.into(db.categoryRules).insert(CategoryRulesCompanion.insert(
        profileId: profileId,
        field: RuleField.description,
        pattern: 'diner',
        category: 'Eating out'));

    await repo.syncSimpleFin(profileId: profileId, client: client, now: now);
    final entries = await db.select(db.budgetEntries).get();
    Map<String, BudgetEntry> by = {for (final e in entries) e.externalId!: e};
    expect(by['CHK:m1']!.category, 'Groceries');
    expect(by['CHK:m1']!.payee, 'Local Grocer');
    expect(by['CHK:m2']!.category, 'Food & Dining');
    expect(by['CHK:m3']!.category, 'Eating out',
        reason: 'a rule beats the merchant code');
  });

  test('any credit on a card is a payment, never income', () async {
    bridge.accounts = [
      {
        'id': 'CC',
        'name': 'Visa (1111)',
        'balance': '-300.00',
        'transactions': [
          txn('a', '25.00', 'Merchant Credit', posted: DateTime(2026, 6, 9)),
          txn('b', '60.00', 'Statement Credit', posted: DateTime(2026, 6, 10)),
          txn('c', '-15.00', 'LUNCH', posted: DateTime(2026, 6, 9)),
        ],
      },
    ];
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: (await feed()).single.id,
        kind: FeedTarget.card);
    await repo.syncSimpleFin(profileId: profileId, client: client, now: now);

    final entries = await db.select(db.budgetEntries).get();
    expect(entries.map((e) => e.description), ['LUNCH']);
    expect(entries.where((e) => e.type == EntryType.income), isEmpty);
    final payments = await db.select(db.payments).get();
    expect(payments.map((p) => p.amountCents).toSet(), {2500, 6000});
  });

  test('categorizing one transaction can move all from the same merchant '
      'and remember it', () async {
    final a = await repo.upsertAccount(AccountsCompanion.insert(
        profileId: profileId, name: 'A', type: AccountType.checking));
    Future<int> add(String desc, String payee) =>
        repo.addBudgetEntry(BudgetEntriesCompanion.insert(
          profileId: profileId,
          date: DateTime(2026, 6, 10),
          amountCents: 1000,
          type: EntryType.expense,
          description: Value(desc),
          payee: Value(payee),
          accountId: Value(a),
        ));
    final first = await add('Dunkin 1', "Dunkin'");
    await add('Dunkin 2', "dunkin'");
    await add('Other store', 'Shop');

    final changed = await repo.setEntryCategory(
        profileId: profileId,
        id: first,
        category: 'Food & Dining',
        applyToSimilar: true);
    expect(changed, 2);
    final entries = await db.select(db.budgetEntries).get();
    expect(entries.where((e) => e.category == 'Food & Dining'), hasLength(2));
    expect(entries.firstWhere((e) => e.payee == 'Shop').category, 'Other');
    final rule = (await db.select(db.categoryRules).get()).single;
    expect(rule.pattern.toLowerCase(), "dunkin'");
    expect(rule.category, 'Food & Dining');

    // Without applyToSimilar only the one entry moves and no rule is made.
    final solo = await add('Cafe', 'Cafe');
    expect(
        await repo.setEntryCategory(
            profileId: profileId, id: solo, category: 'Coffee'),
        1);
    expect(await db.select(db.categoryRules).get(), hasLength(1));
  });

  test('tidying recategorizes "Other" and drops brokerage trades', () async {
    bridge.accounts = [
      {
        'id': 'CHK',
        'name': 'Checking',
        'balance': '100.00',
        'transactions': [
          txn('a', '-9.00', "DOMINO'S"),
          txn('b', '-30.00', 'SQ *ALMOSTAFA LLC'),
        ],
      },
      {
        'id': 'IRA',
        'name': 'Brokerage',
        'balance': '5000.00',
        'transactions': [
          txn('t1', '-1200.00', 'YOU BOUGHT VOYAGER TECHNOLOGIES INC COM'),
          txn('t2', '-300.00', 'REINVESTMENT FIDELITY GOVERNMENT MONEY MARKET'),
          txn('t3', '4.00', 'DIVIDEND RECEIVED'),
        ],
      },
    ];
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    for (final a in await feed()) {
      await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: a.id,
        kind: FeedTarget.account,
        accountType:
            a.name == 'Brokerage' ? AccountType.retirement : AccountType.checking,
      );
    }
    await repo.syncSimpleFin(profileId: profileId, client: client, now: now);

    final entries = await db.select(db.budgetEntries).get();
    final byDesc = {for (final e in entries) e.description!: e};
    expect(byDesc["DOMINO'S"]!.category, 'Food & Dining');
    expect(byDesc['SQ *ALMOSTAFA LLC']!.category, 'Other');
    expect(byDesc.containsKey('YOU BOUGHT VOYAGER TECHNOLOGIES INC COM'),
        isFalse);
    expect(byDesc.keys.any((d) => d.startsWith('REINVESTMENT')), isFalse);
    expect(byDesc['DIVIDEND RECEIVED'], isNotNull,
        reason: 'a dividend is real income');

    // Dropped trades do not come back.
    await repo.syncSimpleFin(profileId: profileId, client: client, now: now);
    expect((await db.select(db.budgetEntries).get()).length, entries.length);
  });

  test('entries imported before payees were kept get one, and a category',
      () async {
    bridge.accounts = [
      {
        'id': 'CHK',
        'name': 'Checking',
        'balance': '100.00',
        'transactions': [
          {
            'id': 'u1',
            'posted': epoch(DateTime(2026, 6, 10)),
            'amount': '-18.00',
            'description': 'UBER   *EATS',
            'payee': 'Uber Eats',
          },
        ],
      },
    ];
    await repo.connectSimpleFin(
        profileId: profileId, setupToken: token(), client: client, now: now);
    final accountId = await repo.createFromSimpleFinAccount(
        profileId: profileId,
        feedAccountId: (await feed()).single.id,
        kind: FeedTarget.account);
    // As an older build left it: imported, no payee, in Other.
    await db.into(db.budgetEntries).insert(BudgetEntriesCompanion.insert(
        profileId: profileId,
        date: DateTime(2026, 6, 10),
        amountCents: 1800,
        type: EntryType.expense,
        description: const Value('UBER   *EATS'),
        accountId: Value(accountId),
        externalId: const Value('CHK:u1')));
    expect(await repo.hasEntriesMissingPayee(profileId, now: now), isTrue);

    await repo.syncSimpleFin(
        profileId: profileId,
        client: client,
        now: now,
        lookback: const Duration(days: 90));
    final e = (await db.select(db.budgetEntries).get()).single;
    expect(e.payee, 'Uber Eats');
    expect(e.category, 'Food & Dining');
    expect(await repo.hasEntriesMissingPayee(profileId, now: now), isFalse);
  });

  test('names an earlier build assigned are renamed, the person\'s own are not',
      () async {
    final a = await repo.upsertAccount(AccountsCompanion.insert(
        profileId: profileId, name: 'A', type: AccountType.checking));
    Future<void> add(String category, {String? ext}) async {
      await db.into(db.budgetEntries).insert(BudgetEntriesCompanion.insert(
          profileId: profileId,
          date: DateTime(2026, 6, 10),
          amountCents: 500,
          type: EntryType.expense,
          category: Value(category),
          accountId: Value(a),
          externalId: Value(ext)));
    }

    await add('Dining', ext: 'X:1');
    await add('Gas', ext: 'X:2');
    await add('Dining'); // typed in by hand: the person's own choice
    await repo.tidyBankEntries(profileId);

    final byExt = {
      for (final e in await db.select(db.budgetEntries).get())
        e.externalId ?? 'manual': e.category,
    };
    expect(byExt['X:1'], 'Food & Dining');
    expect(byExt['X:2'], 'Transportation', reason: 'gas is transportation');
    expect(byExt['manual'], 'Dining');
  });
}
