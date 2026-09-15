import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';

void main() {
  late AppDatabase db;
  late HomebaseRepository repo;
  late int profileId;
  late int checkingId;
  late int cardId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = HomebaseRepository(db);
    profileId = await repo.createProfile(
        ProfilesCompanion.insert(name: 'Owner', isAdmin: const Value(true)));
    checkingId = await repo.upsertAccount(AccountsCompanion.insert(
      profileId: profileId,
      name: 'Checking',
      type: AccountType.checking,
      balanceCents: const Value(500000),
    ));
    cardId = await repo.upsertCard(CreditCardsCompanion.insert(
        profileId: profileId, name: 'Visa', creditLimitCents: 500000));
  });

  tearDown(() => db.close());

  Future<int> addRecurring({
    EntryType type = EntryType.expense,
    int amountCents = 1599,
    DateTime? anchor,
    PayFrequency frequency = PayFrequency.monthly,
    int? accountId,
    int? recurringCardId,
  }) =>
      repo.upsertRecurringTransaction(RecurringTransactionsCompanion.insert(
        profileId: profileId,
        name: 'Netflix',
        type: type,
        amountCents: amountCents,
        frequency: frequency,
        anchorDate: anchor ?? DateTime(2026, 8, 1),
        accountId: Value(accountId),
        cardId: Value(recurringCardId),
      ));

  test('a due expense posts a budget entry and debits the account',
      () async {
    await addRecurring(accountId: checkingId, anchor: DateTime(2026, 8, 1));

    await repo.materializeDueRecurringTransactions(
        profileId: profileId, now: DateTime(2026, 8, 1));

    final entries = await repo
        .watchBudgetForMonth(profileId: profileId, month: DateTime(2026, 8))
        .first;
    expect(entries, hasLength(1));
    expect(entries.single.description, 'Netflix');
    expect(entries.single.amountCents, 1599);

    final account = (await repo.watchAccounts(profileId: profileId).first)
        .firstWhere((a) => a.id == checkingId);
    expect(account.balanceCents, 500000 - 1599);
  });

  test('a due income entry credits the account', () async {
    await addRecurring(
        type: EntryType.income,
        amountCents: 50000,
        accountId: checkingId,
        anchor: DateTime(2026, 8, 1));

    await repo.materializeDueRecurringTransactions(
        profileId: profileId, now: DateTime(2026, 8, 1));

    final account = (await repo.watchAccounts(profileId: profileId).first)
        .firstWhere((a) => a.id == checkingId);
    expect(account.balanceCents, 550000);
  });

  test('an expense charged to a card increases the card balance', () async {
    await addRecurring(recurringCardId: cardId, anchor: DateTime(2026, 8, 1));

    await repo.materializeDueRecurringTransactions(
        profileId: profileId, now: DateTime(2026, 8, 1));

    final card = (await repo.watchCards(profileId: profileId).first)
        .firstWhere((c) => c.id == cardId);
    expect(card.balanceCents, 1599);
  });

  test('with no account or card link, only the budget entry is created',
      () async {
    await addRecurring(anchor: DateTime(2026, 8, 1));

    await repo.materializeDueRecurringTransactions(
        profileId: profileId, now: DateTime(2026, 8, 1));

    final account = (await repo.watchAccounts(profileId: profileId).first)
        .firstWhere((a) => a.id == checkingId);
    expect(account.balanceCents, 500000, reason: 'no link, no balance move');
    final entries = await repo
        .watchBudgetForMonth(profileId: profileId, month: DateTime(2026, 8))
        .first;
    expect(entries, hasLength(1));
  });

  test('a future-dated schedule does not run yet', () async {
    await addRecurring(anchor: DateTime(2026, 9, 1), accountId: checkingId);

    await repo.materializeDueRecurringTransactions(
        profileId: profileId, now: DateTime(2026, 8, 1));

    final account = (await repo.watchAccounts(profileId: profileId).first)
        .firstWhere((a) => a.id == checkingId);
    expect(account.balanceCents, 500000);
  });

  test('running materialize twice does not double-post', () async {
    await addRecurring(accountId: checkingId, anchor: DateTime(2026, 8, 1));

    await repo.materializeDueRecurringTransactions(
        profileId: profileId, now: DateTime(2026, 8, 1));
    await repo.materializeDueRecurringTransactions(
        profileId: profileId, now: DateTime(2026, 8, 1));

    final account = (await repo.watchAccounts(profileId: profileId).first)
        .firstWhere((a) => a.id == checkingId);
    expect(account.balanceCents, 500000 - 1599);
  });

  test('multiple months all run when caught up late', () async {
    await addRecurring(accountId: checkingId, anchor: DateTime(2026, 6, 1));

    await repo.materializeDueRecurringTransactions(
        profileId: profileId, now: DateTime(2026, 8, 15));

    final account = (await repo.watchAccounts(profileId: profileId).first)
        .firstWhere((a) => a.id == checkingId);
    expect(account.balanceCents, 500000 - 1599 * 3);
  });

  test('an inactive schedule never runs', () async {
    final id =
        await addRecurring(accountId: checkingId, anchor: DateTime(2026, 8, 1));
    await repo.upsertRecurringTransaction(RecurringTransactionsCompanion(
      id: Value(id),
      profileId: Value(profileId),
      name: const Value('Netflix'),
      type: const Value(EntryType.expense),
      amountCents: const Value(1599),
      frequency: const Value(PayFrequency.monthly),
      anchorDate: Value(DateTime(2026, 8, 1)),
      accountId: Value(checkingId),
      active: const Value(false),
    ));

    await repo.materializeDueRecurringTransactions(
        profileId: profileId, now: DateTime(2026, 8, 1));

    final account = (await repo.watchAccounts(profileId: profileId).first)
        .firstWhere((a) => a.id == checkingId);
    expect(account.balanceCents, 500000);
  });

  test('deleting the recurring definition reverses every posted occurrence',
      () async {
    final id = await addRecurring(
        accountId: checkingId, anchor: DateTime(2026, 6, 1));
    await repo.materializeDueRecurringTransactions(
        profileId: profileId, now: DateTime(2026, 8, 15));

    await repo.deleteRecurringTransaction(profileId: profileId, id: id);

    final account = (await repo.watchAccounts(profileId: profileId).first)
        .firstWhere((a) => a.id == checkingId);
    expect(account.balanceCents, 500000,
        reason: 'all three months of debits are put back');
    final entries = await repo
        .watchBudgetForMonth(profileId: profileId, month: DateTime(2026, 8))
        .first;
    expect(entries, isEmpty, reason: 'mirrored entries cascade with the log');
  });

  test('deleting the account clears the link but keeps the schedule',
      () async {
    final id = await addRecurring(accountId: checkingId);
    await repo.deleteAccount(profileId: profileId, id: checkingId);

    final recurring =
        (await repo.watchRecurringTransactions(profileId: profileId).first)
            .firstWhere((r) => r.id == id);
    expect(recurring.accountId, isNull);
    expect(recurring.name, 'Netflix');
  });

  test('deleting the card clears the link but keeps the schedule', () async {
    final id = await addRecurring(recurringCardId: cardId);
    await repo.deleteCard(profileId: profileId, id: cardId);

    final recurring =
        (await repo.watchRecurringTransactions(profileId: profileId).first)
            .firstWhere((r) => r.id == id);
    expect(recurring.cardId, isNull);
  });

  test('recurring transactions are per profile', () async {
    final other =
        await repo.createProfile(ProfilesCompanion.insert(name: 'Mom'));
    await addRecurring();

    expect(await repo.watchRecurringTransactions(profileId: other).first,
        isEmpty);
  });
}
