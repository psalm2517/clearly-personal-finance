import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';
import 'package:clearly/data/transaction_draft.dart';

void main() {
  late AppDatabase db;
  late HomebaseRepository repo;
  late int profileId;
  late int checkingId;
  late int savingsId;
  late int cardId;
  late int loanId;

  final now = DateTime(2026, 8, 15, 9, 30);
  final today = DateTime(2026, 8, 15);

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = HomebaseRepository(db);
    profileId = await repo.createProfile(
        ProfilesCompanion.insert(name: 'Owner', isAdmin: const Value(true)));
    checkingId = await repo.upsertAccount(AccountsCompanion.insert(
        profileId: profileId,
        name: 'Checking',
        type: AccountType.checking,
        balanceCents: const Value(500000)));
    savingsId = await repo.upsertAccount(AccountsCompanion.insert(
        profileId: profileId, name: 'Savings', type: AccountType.savings));
    cardId = await repo.upsertCard(CreditCardsCompanion.insert(
        profileId: profileId,
        name: 'Visa',
        creditLimitCents: 500000,
        balanceCents: const Value(100000)));
    loanId = await repo.upsertLoan(LoansCompanion.insert(
        profileId: profileId,
        name: 'Car',
        balanceCents: 900000,
        originalAmountCents: 1000000));
  });

  tearDown(() => db.close());

  Future<void> add(TransactionDraft d) =>
      repo.addTransaction(profileId: profileId, draft: d, now: now);

  Future<int> balance(int id) async =>
      (await repo.watchAccounts(profileId: profileId).first)
          .firstWhere((a) => a.id == id)
          .balanceCents;

  Future<List<BudgetEntry>> entries() => repo
      .watchBudgetForMonth(profileId: profileId, month: DateTime(2026, 8))
      .first;

  group('one-off income and expense', () {
    test('an expense becomes a budget entry on the chosen date and moves the '
        'account', () async {
      await add(TransactionDraft(
        kind: DraftKind.expense,
        amountCents: 4500,
        date: DateTime(2026, 8, 3),
        name: 'Groceries',
        category: 'Food',
        payee: 'Costco',
        accountId: checkingId,
      ));

      final e = (await entries()).single;
      expect(e.type, EntryType.expense);
      expect(e.amountCents, 4500);
      expect(e.date, DateTime(2026, 8, 3), reason: 'backdated, not "now"');
      expect(e.description, 'Groceries');
      expect(e.category, 'Food');
      expect(e.payee, 'Costco');
      expect(await balance(checkingId), 500000 - 4500);
    });

    test('income credits the account', () async {
      await add(TransactionDraft(
        kind: DraftKind.income,
        amountCents: 50000,
        date: today,
        name: 'Refund',
        accountId: checkingId,
      ));

      expect(await balance(checkingId), 550000);
    });

    test('an expense on a card raises the card balance', () async {
      await add(TransactionDraft(
        kind: DraftKind.expense,
        amountCents: 2500,
        date: today,
        cardId: cardId,
      ));

      final card = (await repo.watchCards(profileId: profileId).first)
          .firstWhere((c) => c.id == cardId);
      expect(card.balanceCents, 102500);
    });

    test('splits and tags are saved with the entry', () async {
      await add(TransactionDraft(
        kind: DraftKind.expense,
        amountCents: 15000,
        date: today,
        name: 'Costco',
        splits: const [
          (category: 'Food', amountCents: 10000),
          (category: 'Household', amountCents: 5000),
        ],
        tags: const ['bulk'],
      ));

      final e = (await entries()).single;
      expect(e.category, 'Split');
      expect((await repo.splitsFor(entryId: e.id)).length, 2);
      final tags = await repo.watchEntryTagNames(profileId: profileId).first;
      expect(tags[e.id], ['bulk']);
    });

    test('splits that do not add up are refused', () async {
      expect(
          () => add(TransactionDraft(
                kind: DraftKind.expense,
                amountCents: 15000,
                date: today,
                splits: const [(category: 'Food', amountCents: 100)],
              )),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('repeating', () {
    test('a repeating expense becomes a recurring transaction and posts the '
        'occurrences already due', () async {
      await add(TransactionDraft(
        kind: DraftKind.expense,
        amountCents: 1599,
        date: DateTime(2026, 8, 1),
        name: 'Netflix',
        accountId: checkingId,
        repeats: true,
      ));

      final recurring =
          await repo.watchRecurringTransactions(profileId: profileId).first;
      expect(recurring.single.name, 'Netflix');
      expect(await balance(checkingId), 500000 - 1599,
          reason: 'the August 1 occurrence is already due');
    });

    test('repeating income becomes a paycheck schedule that deposits to the '
        'account', () async {
      await add(TransactionDraft(
        kind: DraftKind.income,
        amountCents: 200000,
        date: DateTime(2026, 8, 14),
        name: 'Day job',
        accountId: checkingId,
        repeats: true,
        frequency: PayFrequency.biweekly,
      ));

      final schedule =
          (await repo.watchSchedules(profileId: profileId).first).single;
      expect(schedule.name, 'Day job');
      expect(schedule.accountId, checkingId);
      expect(await balance(checkingId), 500000 + 200000,
          reason: 'the Aug 14 payday has passed, so it is received and '
              'deposited');
    });

    test('a repeating item needs a name', () async {
      expect(
          () => add(TransactionDraft(
                kind: DraftKind.expense,
                amountCents: 100,
                date: today,
                repeats: true,
              )),
          throwsA(isA<ArgumentError>()));
    });

    test('repeating income cannot go to a card', () async {
      expect(
          () => add(TransactionDraft(
                kind: DraftKind.income,
                amountCents: 100,
                date: today,
                name: 'x',
                cardId: cardId,
                repeats: true,
              )),
          throwsA(isA<ArgumentError>()));
    });

    test('a repeating item may start in the future without posting', () async {
      await add(TransactionDraft(
        kind: DraftKind.expense,
        amountCents: 1599,
        date: DateTime(2026, 9, 1),
        name: 'Netflix',
        accountId: checkingId,
        repeats: true,
      ));

      expect(await balance(checkingId), 500000);
    });
  });

  group('transfers', () {
    test('a one-off transfer moves money and records no budget entry',
        () async {
      await add(TransactionDraft(
        kind: DraftKind.transfer,
        amountCents: 20000,
        date: today,
        accountId: checkingId,
        toAccountId: savingsId,
        targetCategory: 'Save',
      ));

      expect(await balance(checkingId), 480000);
      expect(await balance(savingsId), 20000);
      expect(await entries(), isEmpty);
      final totals = await repo
          .watchTransferTargetTotalsForMonth(
              profileId: profileId, month: DateTime(2026, 8))
          .first;
      expect(totals, {'Save': 20000});
    });

    test('a repeating transfer is scheduled and posts what is already due',
        () async {
      await add(TransactionDraft(
        kind: DraftKind.transfer,
        amountCents: 20000,
        date: DateTime(2026, 8, 1),
        name: 'To savings',
        accountId: checkingId,
        toAccountId: savingsId,
        repeats: true,
      ));

      final scheduled =
          await repo.watchRecurringTransfers(profileId: profileId).first;
      expect(scheduled.single.active, isTrue);
      expect(await balance(savingsId), 20000);
    });

    test('the two accounts must differ and both be chosen', () async {
      expect(
          () => add(TransactionDraft(
                kind: DraftKind.transfer,
                amountCents: 100,
                date: today,
                accountId: checkingId,
                toAccountId: checkingId,
              )),
          throwsA(isA<ArgumentError>()));
      expect(
          () => add(TransactionDraft(
                kind: DraftKind.transfer,
                amountCents: 100,
                date: today,
                accountId: checkingId,
              )),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('payments', () {
    test('a card payment reduces the card and the account it came from',
        () async {
      await add(TransactionDraft(
        kind: DraftKind.payment,
        amountCents: 30000,
        date: today,
        payableType: PaymentAccountType.card,
        payableId: cardId,
        accountId: checkingId,
        note: 'August',
      ));

      final card = (await repo.watchCards(profileId: profileId).first)
          .firstWhere((c) => c.id == cardId);
      expect(card.balanceCents, 70000);
      expect(await balance(checkingId), 470000);
    });

    test('a loan payment reduces the loan', () async {
      await add(TransactionDraft(
        kind: DraftKind.payment,
        amountCents: 50000,
        date: today,
        payableType: PaymentAccountType.loan,
        payableId: loanId,
      ));

      final loan = (await repo.watchLoans(profileId: profileId).first)
          .firstWhere((l) => l.id == loanId);
      expect(loan.balanceCents, 850000);
    });

    test('a payment must name what it paid and cannot repeat', () async {
      expect(
          () => add(TransactionDraft(
              kind: DraftKind.payment, amountCents: 100, date: today)),
          throwsA(isA<ArgumentError>()));
      expect(
          () => add(TransactionDraft(
                kind: DraftKind.payment,
                amountCents: 100,
                date: today,
                payableType: PaymentAccountType.card,
                payableId: cardId,
                repeats: true,
              )),
          throwsA(isA<ArgumentError>()));
    });
  });

  group('validation common to every kind', () {
    test('an amount of zero or less is refused', () async {
      for (final cents in [0, -5]) {
        expect(
            () => add(TransactionDraft(
                kind: DraftKind.expense, amountCents: cents, date: today)),
            throwsA(isA<ArgumentError>()));
      }
    });

    test('a one-off cannot be dated in the future', () async {
      expect(
          () => add(TransactionDraft(
              kind: DraftKind.expense,
              amountCents: 100,
              date: DateTime(2026, 8, 20))),
          throwsA(isA<ArgumentError>()));
    });

    test('an account and a card together are refused', () async {
      expect(
          () => add(TransactionDraft(
                kind: DraftKind.expense,
                amountCents: 100,
                date: today,
                accountId: checkingId,
                cardId: cardId,
              )),
          throwsA(isA<ArgumentError>()));
    });
  });
}
