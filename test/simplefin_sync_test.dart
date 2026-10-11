import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';
import 'package:clearly/data/simplefin.dart';

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
}
