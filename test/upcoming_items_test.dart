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

  DateTime daysFromNow(int d) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day + d);
  }

  test('a bill due in the window shows as a negative amount', () async {
    await repo.upsertBill(BillsCompanion.insert(
      profileId: profileId,
      name: 'Rent',
      amountCents: 145000,
      dueDay: daysFromNow(5).day,
    ));

    final items = await repo.upcomingItems(profileId: profileId, days: 30);

    final rent = items.firstWhere((i) => i.label == 'Rent');
    expect(rent.amountCents, -145000);
    expect(rent.kind, UpcomingKind.bill);
  });

  test('a paycheck in the window shows as a positive amount', () async {
    await repo.upsertPaycheck(PaychecksCompanion.insert(
      profileId: profileId,
      name: 'Job',
      date: daysFromNow(3),
      amountCents: 200000,
    ));

    final items = await repo.upcomingItems(profileId: profileId, days: 30);

    final job = items.firstWhere((i) => i.label == 'Job');
    expect(job.amountCents, 200000);
    expect(job.kind, UpcomingKind.paycheck);
  });

  test('an active transfer occurrence shows as a negative amount from the '
      'source side', () async {
    final savings = await repo.upsertAccount(AccountsCompanion.insert(
        profileId: profileId, name: 'Savings', type: AccountType.savings));
    await repo.upsertRecurringTransfer(RecurringTransfersCompanion.insert(
      profileId: profileId,
      name: 'To savings',
      fromAccountId: checkingId,
      toAccountId: savings,
      amountCents: 20000,
      frequency: PayFrequency.monthly,
      anchorDate: daysFromNow(2),
    ));

    final items = await repo.upcomingItems(profileId: profileId, days: 30);

    final transfer = items.firstWhere((i) => i.label == 'To savings');
    expect(transfer.amountCents, -20000);
    expect(transfer.kind, UpcomingKind.transfer);
  });

  test('an inactive transfer never appears', () async {
    final savings = await repo.upsertAccount(AccountsCompanion.insert(
        profileId: profileId, name: 'Savings', type: AccountType.savings));
    final id = await repo.upsertRecurringTransfer(
        RecurringTransfersCompanion.insert(
      profileId: profileId,
      name: 'To savings',
      fromAccountId: checkingId,
      toAccountId: savings,
      amountCents: 20000,
      frequency: PayFrequency.monthly,
      anchorDate: daysFromNow(2),
    ));
    await repo.upsertRecurringTransfer(RecurringTransfersCompanion(
      id: Value(id),
      profileId: Value(profileId),
      name: const Value('To savings'),
      fromAccountId: Value(checkingId),
      toAccountId: Value(savings),
      amountCents: const Value(20000),
      frequency: const Value(PayFrequency.monthly),
      anchorDate: Value(daysFromNow(2)),
      active: const Value(false),
    ));

    final items = await repo.upcomingItems(profileId: profileId, days: 30);

    expect(items.where((i) => i.kind == UpcomingKind.transfer), isEmpty);
  });

  test('a general recurring transaction shows with the right sign',
      () async {
    await repo.upsertRecurringTransaction(RecurringTransactionsCompanion.insert(
      profileId: profileId,
      name: 'Netflix',
      type: EntryType.expense,
      amountCents: 1599,
      frequency: PayFrequency.monthly,
      anchorDate: daysFromNow(4),
    ));

    final items = await repo.upcomingItems(profileId: profileId, days: 30);

    final netflix = items.firstWhere((i) => i.label == 'Netflix');
    expect(netflix.amountCents, -1599);
    expect(netflix.kind, UpcomingKind.recurring);
  });

  test('items outside the window are excluded', () async {
    final farFuture = DateTime.now().year + 5;
    await repo.upsertBill(BillsCompanion.insert(
      profileId: profileId,
      name: 'One-time fee',
      amountCents: 9900,
      dueDay: 1,
      frequency: const Value(BillFrequency.oneTime),
      dueMonth: const Value(1),
      dueYear: Value(farFuture),
    ));

    final items = await repo.upcomingItems(profileId: profileId, days: 30);

    expect(items.where((i) => i.label == 'One-time fee'), isEmpty);
  });

  test('everything is sorted chronologically regardless of source',
      () async {
    await repo.upsertBill(BillsCompanion.insert(
      profileId: profileId,
      name: 'Rent',
      amountCents: 145000,
      dueDay: daysFromNow(10).day,
    ));
    await repo.upsertPaycheck(PaychecksCompanion.insert(
      profileId: profileId,
      name: 'Job',
      date: daysFromNow(3),
      amountCents: 200000,
    ));

    final items = await repo.upcomingItems(profileId: profileId, days: 30);

    final dates = items.map((i) => i.date).toList();
    final sorted = [...dates]..sort();
    expect(dates, sorted);
  });

  test('a bill that is already paid is not listed as upcoming', () async {
    final due = daysFromNow(5);
    final bill = await repo.upsertBill(BillsCompanion.insert(
      profileId: profileId,
      name: 'Rent',
      amountCents: 145000,
      dueDay: due.day,
    ));
    await repo.setBillPaid(
        profileId: profileId,
        billId: bill,
        month: DateTime(due.year, due.month),
        paid: true);

    final items = await repo.upcomingItems(profileId: profileId, days: 30);

    expect(
        items.where((i) => i.label == 'Rent' &&
            i.date == DateTime(due.year, due.month, due.day)),
        isEmpty);
  });
}
