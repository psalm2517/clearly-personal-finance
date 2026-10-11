import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';
import 'package:clearly/main.dart';
import 'package:clearly/theme/catppuccin.dart';
import 'package:clearly/widgets/spending_by_category.dart';

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  testWidgets('categories are largest first, open to their transactions, and '
      'a transaction can be moved', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = HomebaseRepository(db);
    late Profile profile;
    late List<BudgetEntry> entries;
    await tester.runAsync(() async {
      final id = await repo.createProfile(
          ProfilesCompanion.insert(name: 'Owner', isAdmin: const Value(true)));
      profile = (await repo.profileById(id))!;
      Future<void> add(String desc, int cents, String category) =>
          repo.addBudgetEntry(BudgetEntriesCompanion.insert(
            profileId: id,
            date: DateTime(2026, 6, 10),
            amountCents: cents,
            type: EntryType.expense,
            category: Value(category),
            description: Value(desc),
          ));
      await add('Safeway', 12000, 'Groceries');
      await add('Chipotle', 3000, 'Dining');
      await add('Mystery', 5000, 'Other');
      entries = await db.select(db.budgetEntries).get();
    });

    await tester.binding.setSurfaceSize(const Size(1000, 900));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        loggedInProfileProvider.overrideWith((ref) => profile),
      ],
      child: MaterialApp(
        theme: themeFor(CatppuccinFlavor.mocha),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SpendingByCategory(
              entries: entries,
              splits: const {},
              previousTotals: const {'Groceries': 10000},
            ),
          ),
        ),
      ),
    ));
    await settle(tester);

    // Largest first, with share and the change from last month.
    final order = ['Groceries', 'Other', 'Dining']
        .map((c) => tester.getTopLeft(find.text(c)).dy)
        .toList();
    expect(order[0] < order[1] && order[1] < order[2], isTrue);
    expect(find.text('60%'), findsOneWidget); // 12000 of 20000
    expect(find.textContaining('\$20.00'), findsWidgets); // ↑ vs 100.00

    // Opening a category shows its transactions.
    expect(find.text('Mystery'), findsNothing);
    await tester.tap(find.text('Other'));
    await settle(tester);
    expect(find.text('Mystery'), findsOneWidget);

    // Moving it to a new category.
    await tester.tap(find.text('Categorize'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'Gifts');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);
    final after = await tester.runAsync(() => db.select(db.budgetEntries).get());
    expect(after!.firstWhere((e) => e.description == 'Mystery').category,
        'Gifts');

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
  });
}
