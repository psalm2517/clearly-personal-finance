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

  test('a bill paid with a card mirrors into an entry carrying that card, one '
      'paid from an account carries the account', () async {
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

    final all = await entries();
    final streaming = all.firstWhere((e) => e.description == 'Streaming');
    final rent = all.firstWhere((e) => e.description == 'Rent');

    expect(streaming.cardId, cardId);
    expect(streaming.accountId, isNull);
    expect(rent.accountId, checkingId);
    expect(rent.cardId, isNull);

    final history =
        await repo.watchCardHistory(profileId: profileId, cardId: cardId).first;
    expect(history.map((a) => a.label), contains('Streaming'),
        reason: 'the bill now shows in the card\'s own history');
  });

  test('card payments can be left out of the month\'s money movements',
      () async {
    await repo.postManualTransfer(
      profileId: profileId,
      fromAccountId: checkingId,
      toAccountId: (await repo.upsertAccount(AccountsCompanion.insert(
          profileId: profileId, name: 'Savings', type: AccountType.savings))),
      amountCents: 15000,
      date: DateTime(2026, 8, 10),
      name: 'To savings',
    );
    await repo.addPayment(
      profileId: profileId,
      accountType: PaymentAccountType.card,
      accountId: cardId,
      amountCents: 20000,
      date: DateTime(2026, 8, 12),
      fromAccountId: checkingId,
    );

    final all = await repo
        .watchRealMoneyMovementsForMonth(
            profileId: profileId, month: DateTime(2026, 8))
        .first;
    final withoutCards = await repo
        .watchRealMoneyMovementsForMonth(
            profileId: profileId,
            month: DateTime(2026, 8),
            includeCardPayments: false)
        .first;

    expect(all.keys, containsAll(['Transfer to Savings', 'Card payment — Visa']));
    expect(withoutCards.keys, ['Transfer to Savings'],
        reason: 'the transfer stays; the card payment would double count '
            'purchases already counted as spending');
  });
}
