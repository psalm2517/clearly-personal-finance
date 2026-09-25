import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';

/// Editing a row must return that row's own id and touch only that row —
/// regardless of what else was inserted in between. insertOnConflictUpdate
/// returned last_insert_rowid() on its update branch, i.e. an unrelated id.
void main() {
  late AppDatabase db;
  late HomebaseRepository repo;
  late int profileId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = HomebaseRepository(db);
    profileId = await repo.createProfile(
        ProfilesCompanion.insert(name: 'Owner', isAdmin: const Value(true)));
  });

  tearDown(() => db.close());

  Future<void> churn() async {
    for (var i = 0; i < 5; i++) {
      await repo.addBudgetEntry(BudgetEntriesCompanion.insert(
          profileId: profileId,
          date: DateTime(2026, 8, 2),
          amountCents: 100,
          type: EntryType.expense));
    }
  }

  test('marking a paycheck received after other inserts syncs its income '
      'entry instead of throwing', () async {
    final a = await repo.upsertPaycheck(PaychecksCompanion.insert(
        profileId: profileId,
        name: 'A',
        date: DateTime(2026, 8, 1),
        amountCents: 100000));
    await repo.upsertPaycheck(PaychecksCompanion.insert(
        profileId: profileId,
        name: 'B',
        date: DateTime(2026, 8, 15),
        amountCents: 200000));
    await churn();

    final id = await repo.upsertPaycheck(PaychecksCompanion(
      id: Value(a),
      profileId: Value(profileId),
      name: const Value('A'),
      date: Value(DateTime(2026, 8, 1)),
      amountCents: const Value(100000),
      received: const Value(true),
    ));

    expect(id, a);
    final entries = await repo
        .watchBudgetForMonth(profileId: profileId, month: DateTime(2026, 8))
        .first;
    final income = entries.where((e) => e.type == EntryType.income).toList();
    expect(income, hasLength(1));
    expect(income.single.description, 'A');
    expect(income.single.amountCents, 100000);
  });

  test('editing a card, loan, bill, goal, schedule or transfer returns its '
      'own id', () async {
    final card = await repo.upsertCard(CreditCardsCompanion.insert(
        profileId: profileId, name: 'Visa', creditLimitCents: 100000));
    final loan = await repo.upsertLoan(LoansCompanion.insert(
        profileId: profileId,
        name: 'Car',
        balanceCents: 500000,
        originalAmountCents: 800000));
    final bill = await repo.upsertBill(BillsCompanion.insert(
        profileId: profileId, name: 'Phone', amountCents: 8000, dueDay: 5));
    final goal = await repo.upsertGoal(GoalsCompanion.insert(
        profileId: profileId,
        name: 'Fund',
        type: GoalType.savings,
        targetAmountCents: 100000));
    final schedule = await repo.upsertSchedule(PaycheckSchedulesCompanion.insert(
        profileId: profileId,
        name: 'Job',
        frequency: PayFrequency.weekly,
        anchorDate: DateTime(2026, 8, 1),
        amountCents: 100000));
    final from = await repo.upsertAccount(AccountsCompanion.insert(
        profileId: profileId, name: 'A', type: AccountType.checking));
    final to = await repo.upsertAccount(AccountsCompanion.insert(
        profileId: profileId, name: 'B', type: AccountType.savings));
    final transfer = await repo.upsertRecurringTransfer(
        RecurringTransfersCompanion.insert(
            profileId: profileId,
            name: 'Move',
            fromAccountId: from,
            toAccountId: to,
            amountCents: 1000,
            frequency: PayFrequency.monthly,
            anchorDate: DateTime(2026, 8, 1)));
    await churn();

    expect(
        await repo.upsertCard(CreditCardsCompanion(
            id: Value(card),
            profileId: Value(profileId),
            name: const Value('Visa 2'),
            creditLimitCents: const Value(100000))),
        card);
    expect(
        await repo.upsertLoan(LoansCompanion(
            id: Value(loan),
            profileId: Value(profileId),
            name: const Value('Car 2'),
            balanceCents: const Value(1),
            originalAmountCents: const Value(1))),
        loan);
    expect(
        await repo.upsertBill(BillsCompanion(
            id: Value(bill),
            profileId: Value(profileId),
            name: const Value('Phone 2'),
            amountCents: const Value(1),
            dueDay: const Value(1))),
        bill);
    expect(
        await repo.upsertGoal(GoalsCompanion(
            id: Value(goal),
            profileId: Value(profileId),
            name: const Value('Fund 2'),
            type: const Value(GoalType.savings),
            targetAmountCents: const Value(1))),
        goal);
    expect(
        await repo.upsertSchedule(PaycheckSchedulesCompanion(
            id: Value(schedule),
            profileId: Value(profileId),
            name: const Value('Job 2'),
            frequency: const Value(PayFrequency.weekly),
            anchorDate: Value(DateTime(2026, 8, 1)),
            amountCents: const Value(1))),
        schedule);
    expect(
        await repo.upsertRecurringTransfer(RecurringTransfersCompanion(
            id: Value(transfer),
            profileId: Value(profileId),
            name: const Value('Move 2'),
            fromAccountId: Value(from),
            toAccountId: Value(to),
            amountCents: const Value(1),
            frequency: const Value(PayFrequency.monthly),
            anchorDate: Value(DateTime(2026, 8, 1)))),
        transfer);
  });
}
