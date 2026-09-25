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

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = HomebaseRepository(db);
    profileId = await repo.createProfile(
        ProfilesCompanion.insert(name: 'Owner', isAdmin: const Value(true)));
    checkingId = await repo.upsertAccount(AccountsCompanion.insert(
        profileId: profileId,
        name: 'Checking',
        type: AccountType.checking,
        balanceCents: const Value(100000)));
  });

  tearDown(() => db.close());

  Future<int> balance() async =>
      (await repo.watchAccounts(profileId: profileId).first)
          .firstWhere((a) => a.id == checkingId)
          .balanceCents;

  Future<int> addPaycheck({
    int? accountId,
    bool received = false,
    int amount = 200000,
    int bonus = 0,
    DateTime? date,
  }) =>
      repo.upsertPaycheck(PaychecksCompanion.insert(
        profileId: profileId,
        name: 'Job',
        date: date ?? DateTime(2026, 8, 15),
        amountCents: amount,
        bonusCents: Value(bonus),
        received: Value(received),
        accountId: Value(accountId),
      ));

  Future<void> edit(int id,
      {int? accountId, bool received = true, int amount = 200000, int bonus = 0}) {
    return repo.upsertPaycheck(PaychecksCompanion(
      id: Value(id),
      profileId: Value(profileId),
      name: const Value('Job'),
      date: Value(DateTime(2026, 8, 15)),
      amountCents: Value(amount),
      bonusCents: Value(bonus),
      received: Value(received),
      accountId: Value(accountId),
    ));
  }

  test('a received paycheck credits its deposit account, bonus included',
      () async {
    await addPaycheck(
        accountId: checkingId, received: true, amount: 200000, bonus: 50000);

    expect(await balance(), 100000 + 250000);
    final entries = await repo
        .watchBudgetForMonth(profileId: profileId, month: DateTime(2026, 8))
        .first;
    expect(entries.single.accountId, checkingId,
        reason: 'the income entry shows up in that account\'s history');
  });

  test('a received paycheck with no deposit account leaves balances alone',
      () async {
    await addPaycheck(received: true);

    expect(await balance(), 100000);
  });

  test('an unreceived paycheck credits nothing', () async {
    await addPaycheck(accountId: checkingId);

    expect(await balance(), 100000);
  });

  test('un-receiving a paycheck takes the credit back', () async {
    final id = await addPaycheck(accountId: checkingId, received: true);
    await edit(id, accountId: checkingId, received: false);

    expect(await balance(), 100000);
  });

  test('changing the amount of a received paycheck corrects the balance',
      () async {
    final id = await addPaycheck(accountId: checkingId, received: true);
    await edit(id, accountId: checkingId, amount: 150000);

    expect(await balance(), 100000 + 150000);
  });

  test('saving a received paycheck again does not credit it twice', () async {
    final id = await addPaycheck(accountId: checkingId, received: true);
    await edit(id, accountId: checkingId);
    await edit(id, accountId: checkingId);

    expect(await balance(), 100000 + 200000);
  });

  test('deleting a received paycheck takes its credit back', () async {
    final id = await addPaycheck(accountId: checkingId, received: true);

    await repo.deletePaycheck(profileId: profileId, id: id);

    expect(await balance(), 100000);
  });

  test('a schedule\'s deposit account is copied onto generated paychecks, and '
      'follows a later change until they are received', () async {
    final savings = await repo.upsertAccount(AccountsCompanion.insert(
        profileId: profileId, name: 'Savings', type: AccountType.savings));
    final schedule = await repo.upsertSchedule(PaycheckSchedulesCompanion.insert(
      profileId: profileId,
      name: 'Job',
      frequency: PayFrequency.weekly,
      anchorDate: DateTime(2026, 8, 1),
      amountCents: 100000,
      accountId: Value(checkingId),
    ));
    await repo.generateDuePaychecks(
        profileId: profileId, until: DateTime(2026, 8, 20));
    var checks = await repo.watchPaychecks(profileId: profileId).first;
    expect(checks.every((p) => p.accountId == checkingId), isTrue);

    await repo.upsertSchedule(PaycheckSchedulesCompanion(
      id: Value(schedule),
      profileId: Value(profileId),
      name: const Value('Job'),
      frequency: const Value(PayFrequency.weekly),
      anchorDate: Value(DateTime(2026, 8, 1)),
      amountCents: const Value(100000),
      accountId: Value(savings),
    ));
    checks = await repo.watchPaychecks(profileId: profileId).first;
    expect(checks.every((p) => p.accountId == savings), isTrue);
  });

  test('deleting the deposit account clears the link instead of failing',
      () async {
    final id = await addPaycheck(accountId: checkingId);
    await repo.upsertSchedule(PaycheckSchedulesCompanion.insert(
      profileId: profileId,
      name: 'Job',
      frequency: PayFrequency.weekly,
      anchorDate: DateTime(2026, 8, 1),
      amountCents: 100000,
      accountId: Value(checkingId),
    ));

    await repo.deleteAccount(profileId: profileId, id: checkingId);

    final check = (await repo.watchPaychecks(profileId: profileId).first)
        .firstWhere((p) => p.id == id);
    expect(check.accountId, isNull);
    final schedule =
        (await repo.watchSchedules(profileId: profileId).first).single;
    expect(schedule.accountId, isNull);
  });

  DateTime daysFromNow(int d) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + d);
  }

  test('the projection does not add a paycheck already credited to an account',
      () async {
    await addPaycheck(
        accountId: checkingId, received: true, date: daysFromNow(0));

    final points = await repo.projectCashFlow(profileId: profileId, days: 3);

    expect(points.last.balanceCents, 100000 + 200000,
        reason: 'credited once, by receiving it, not again by the projection');
  });

  test('a received paycheck is not listed as upcoming', () async {
    await addPaycheck(
        accountId: checkingId, received: true, date: daysFromNow(0));

    final items = await repo.upcomingItems(profileId: profileId, days: 10);

    expect(items.where((i) => i.kind == UpcomingKind.paycheck), isEmpty);
  });
}
