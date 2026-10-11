import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';
import 'package:clearly/main.dart';
import 'package:clearly/theme/catppuccin.dart';
import 'package:clearly/widgets/category_rules.dart';

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  testWidgets('a rule made in the dialog moves what is already there',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = HomebaseRepository(db);
    late Profile profile;
    await tester.runAsync(() async {
      final id = await repo.createProfile(
          ProfilesCompanion.insert(name: 'Owner', isAdmin: const Value(true)));
      profile = (await repo.profileById(id))!;
      await repo.addBudgetEntry(BudgetEntriesCompanion.insert(
          profileId: id,
          date: DateTime(2026, 6, 10),
          amountCents: 2500,
          type: EntryType.expense,
          description: const Value('FANDUEL SPORTSBOOK')));
    });

    await tester.binding.setSurfaceSize(const Size(1100, 900));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        loggedInProfileProvider.overrideWith((ref) => profile),
      ],
      child: MaterialApp(
        theme: themeFor(CatppuccinFlavor.mocha),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showCategoryRules(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);

    expect(find.text('No rules yet. Add one above, or pick from the '
        'suggestions.'), findsOneWidget);

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'FANDUEL');
    await tester.enterText(fields.at(1), 'Entertainment');
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await settle(tester);

    expect(find.textContaining('Moved 1 transactions'), findsOneWidget);
    expect(find.text('contains "FANDUEL"'), findsOneWidget);
    final e = await tester.runAsync(() => db.select(db.budgetEntries).get());
    expect(e!.single.category, 'Entertainment');

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
  });
}
