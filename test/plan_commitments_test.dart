import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';

void main() {
  group('planCommitments counts each category once', () {
    test('categories with no overlap simply add up', () {
      final plan = HomebaseRepository.planCommitments(
        targetByCategory: {'Save': 50000, 'Invest': 40000},
        billsDueByCategory: {'Phone': 8000, 'Subscription': 1599},
      );
      expect(plan.targetsCents, 90000);
      expect(plan.billsBeyondTargetsCents, 9599);
    });

    test('a bill inside a category that has a bigger target is not added on '
        'top of it', () {
      final plan = HomebaseRepository.planCommitments(
        targetByCategory: {'Utilities': 20000},
        billsDueByCategory: {'Utilities': 15000},
      );
      expect(plan.targetsCents, 20000);
      expect(plan.billsBeyondTargetsCents, 0,
          reason: 'the \$150 of bills is already part of the \$200 target');
    });

    test('bills that exceed their category target count for the excess only',
        () {
      final plan = HomebaseRepository.planCommitments(
        targetByCategory: {'Utilities': 10000},
        billsDueByCategory: {'Utilities': 15000},
      );
      expect(plan.targetsCents, 10000);
      expect(plan.billsBeyondTargetsCents, 5000);
      expect(plan.targetsCents + plan.billsBeyondTargetsCents, 15000,
          reason: 'the category is planned at whichever is bigger');
    });

    test('with no targets every bill counts', () {
      final plan = HomebaseRepository.planCommitments(
        targetByCategory: {},
        billsDueByCategory: {'Rent': 145000, 'Phone': 8000},
      );
      expect(plan.targetsCents, 0);
      expect(plan.billsBeyondTargetsCents, 153000);
    });

    test('with no bills only the targets count', () {
      final plan = HomebaseRepository.planCommitments(
        targetByCategory: {'Food': 40000},
        billsDueByCategory: {},
      );
      expect(plan.targetsCents, 40000);
      expect(plan.billsBeyondTargetsCents, 0);
    });
  });

  group('watchBillsDueByCategoryForMonth', () {
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

    test('adds bills up by category, only those that charge in the month, '
        'plus monthly card fees', () async {
      await repo.upsertBill(BillsCompanion.insert(
          profileId: profileId,
          name: 'Phone',
          amountCents: 8000,
          dueDay: 5,
          category: const Value('Phone')));
      await repo.upsertBill(BillsCompanion.insert(
          profileId: profileId,
          name: 'Phone 2',
          amountCents: 2000,
          dueDay: 6,
          category: const Value('Phone')));
      await repo.upsertBill(BillsCompanion.insert(
          profileId: profileId,
          name: 'Insurance',
          amountCents: 60000,
          dueDay: 1,
          frequency: const Value(BillFrequency.quarterly),
          dueMonth: const Value(1),
          category: const Value('Insurance')));
      await repo.upsertCard(CreditCardsCompanion.insert(
          profileId: profileId,
          name: 'Visa',
          creditLimitCents: 100000,
          monthlyFeeCents: const Value(500)));

      // Quarterly from January lands in Jan, Apr, Jul, Oct.
      final april = await repo
          .watchBillsDueByCategoryForMonth(
              profileId: profileId, month: DateTime(2026, 4))
          .first;
      expect(april, {'Phone': 10000, 'Insurance': 60000, 'Card fees': 500});

      final march = await repo
          .watchBillsDueByCategoryForMonth(
              profileId: profileId, month: DateTime(2026, 3))
          .first;
      expect(march, {'Phone': 10000, 'Card fees': 500});
    });
  });
}
