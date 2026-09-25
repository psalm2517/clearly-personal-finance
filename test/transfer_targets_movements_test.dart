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
  late int portfolioId;

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
    portfolioId = await repo.upsertAccount(AccountsCompanion.insert(
        profileId: profileId,
        name: 'Core Portfolio',
        type: AccountType.retirement));
  });

  tearDown(() => db.close());

  final august = DateTime(2026, 8);

  group('transfer target totals', () {
    test('a transfer with a category counts toward it in its month', () async {
      await repo.postManualTransfer(
        profileId: profileId,
        fromAccountId: checkingId,
        toAccountId: portfolioId,
        amountCents: 15000,
        date: DateTime(2026, 8, 10),
        name: 'Invest',
        targetCategory: 'Invest',
      );

      final totals = await repo
          .watchTransferTargetTotalsForMonth(profileId: profileId, month: august)
          .first;
      expect(totals, {'Invest': 15000});
    });

    test('a transfer without a category counts toward nothing', () async {
      await repo.postManualTransfer(
        profileId: profileId,
        fromAccountId: checkingId,
        toAccountId: portfolioId,
        amountCents: 15000,
        date: DateTime(2026, 8, 10),
        name: 'Invest',
      );

      final totals = await repo
          .watchTransferTargetTotalsForMonth(profileId: profileId, month: august)
          .first;
      expect(totals, isEmpty);
    });

    test('only the requested month counts, and amounts add up', () async {
      for (final d in [DateTime(2026, 8, 3), DateTime(2026, 8, 20)]) {
        await repo.postManualTransfer(
          profileId: profileId,
          fromAccountId: checkingId,
          toAccountId: portfolioId,
          amountCents: 10000,
          date: d,
          name: 'Invest',
          targetCategory: 'Invest',
        );
      }
      await repo.postManualTransfer(
        profileId: profileId,
        fromAccountId: checkingId,
        toAccountId: portfolioId,
        amountCents: 99999,
        date: DateTime(2026, 9, 2),
        name: 'Invest',
        targetCategory: 'Invest',
      );

      final totals = await repo
          .watchTransferTargetTotalsForMonth(profileId: profileId, month: august)
          .first;
      expect(totals, {'Invest': 20000});
    });

    test('a transfer still creates no budget entry', () async {
      await repo.postManualTransfer(
        profileId: profileId,
        fromAccountId: checkingId,
        toAccountId: portfolioId,
        amountCents: 15000,
        date: DateTime(2026, 8, 10),
        name: 'Invest',
        targetCategory: 'Invest',
      );

      expect(
          await repo
              .watchBudgetForMonth(profileId: profileId, month: august)
              .first,
          isEmpty);
    });
  });

  group('movements', () {
    test('transfers and card/loan payments are listed, newest first', () async {
      final card = await repo.upsertCard(CreditCardsCompanion.insert(
          profileId: profileId, name: 'Visa', creditLimitCents: 500000,
          balanceCents: const Value(50000)));
      await repo.postManualTransfer(
        profileId: profileId,
        fromAccountId: checkingId,
        toAccountId: portfolioId,
        amountCents: 15000,
        date: DateTime(2026, 8, 10),
        name: 'Invest',
      );
      await repo.addPayment(
        profileId: profileId,
        accountType: PaymentAccountType.card,
        accountId: card,
        amountCents: 20000,
        date: DateTime(2026, 8, 20),
        fromAccountId: checkingId,
      );

      final movements = await repo.watchMovements(profileId: profileId).first;

      expect(movements, hasLength(2));
      expect(movements.first.kind, MovementKind.cardPayment);
      expect(movements.first.label, 'Card payment — Visa');
      expect(movements.first.cardId, card);
      expect(movements.first.fromAccountId, checkingId);
      expect(movements.last.kind, MovementKind.transfer);
      expect(movements.last.fromAccountId, checkingId);
      expect(movements.last.toAccountId, portfolioId);
      expect(movements.last.amountCents, 15000);
    });

    test('movements are per profile', () async {
      final other =
          await repo.createProfile(ProfilesCompanion.insert(name: 'Mom'));
      await repo.postManualTransfer(
        profileId: profileId,
        fromAccountId: checkingId,
        toAccountId: portfolioId,
        amountCents: 15000,
        date: DateTime(2026, 8, 10),
        name: 'Invest',
      );

      expect(await repo.watchMovements(profileId: other).first, isEmpty);
    });
  });

  test('the CSV export includes transfers and payments with their type',
      () async {
    await repo.postManualTransfer(
      profileId: profileId,
      fromAccountId: checkingId,
      toAccountId: portfolioId,
      amountCents: 15000,
      date: DateTime(2026, 8, 10),
      name: 'Invest',
    );

    final csv = await repo.exportEntriesAsCsv(profileId: profileId);

    expect(csv, contains('transfer'));
    expect(csv, contains('150.00'));
    expect(csv, contains('Checking to Core Portfolio'));
  });
}
