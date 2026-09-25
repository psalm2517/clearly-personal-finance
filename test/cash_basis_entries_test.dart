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
        balanceCents: const Value(100000)));
    cardId = await repo.upsertCard(CreditCardsCompanion.insert(
        profileId: profileId, name: 'Visa', creditLimitCents: 500000));
  });

  tearDown(() => db.close());

  Future<List<BudgetEntry>> entries() => repo
      .watchBudgetForMonth(profileId: profileId, month: DateTime(2026, 8))
      .first;

  test('an entry charged to a card does not move cash', () async {
    await repo.addBudgetEntry(BudgetEntriesCompanion.insert(
      profileId: profileId,
      date: DateTime(2026, 8, 10),
      amountCents: 4500,
      type: EntryType.expense,
      cardId: Value(cardId),
    ));

    expect(HomebaseRepository.entryMovesCash((await entries()).single, {}),
        isFalse);
  });

  test('an account-linked or unlinked entry moves cash', () async {
    await repo.addBudgetEntry(BudgetEntriesCompanion.insert(
      profileId: profileId,
      date: DateTime(2026, 8, 10),
      amountCents: 4500,
      type: EntryType.expense,
      accountId: Value(checkingId),
    ));
    await repo.addBudgetEntry(BudgetEntriesCompanion.insert(
      profileId: profileId,
      date: DateTime(2026, 8, 11),
      amountCents: 1000,
      type: EntryType.expense,
    ));

    for (final e in await entries()) {
      expect(HomebaseRepository.entryMovesCash(e, {}), isTrue);
    }
  });

  test('an entry listed as card-billed does not move cash', () async {
    await repo.addBudgetEntry(BudgetEntriesCompanion.insert(
      profileId: profileId,
      date: DateTime(2026, 8, 10),
      amountCents: 4500,
      type: EntryType.expense,
    ));
    final e = (await entries()).single;

    expect(HomebaseRepository.entryMovesCash(e, {e.id}), isFalse);
  });

  test('a bill paid with a card is found, one paid from an account is not',
      () async {
    final cardBill = await repo.upsertBill(BillsCompanion.insert(
      profileId: profileId,
      name: 'Streaming',
      amountCents: 1599,
      dueDay: 10,
      paymentSourceType: const Value(PaymentSourceType.card),
      paymentSourceId: Value(cardId),
    ));
    final accountBill = await repo.upsertBill(BillsCompanion.insert(
      profileId: profileId,
      name: 'Rent',
      amountCents: 100000,
      dueDay: 1,
      paymentSourceType: const Value(PaymentSourceType.account),
      paymentSourceId: Value(checkingId),
    ));
    final month = DateTime(2026, 8);
    await repo.setBillPaid(
        profileId: profileId, billId: cardBill, month: month, paid: true);
    await repo.setBillPaid(
        profileId: profileId, billId: accountBill, month: month, paid: true);

    final ids = await repo.watchCardBilledBillEntryIds(profileId: profileId).first;
    final all = await entries();
    final streaming = all.firstWhere((e) => e.description == 'Streaming');
    final rent = all.firstWhere((e) => e.description == 'Rent');

    expect(ids, contains(streaming.id));
    expect(ids, isNot(contains(rent.id)));
  });
}
