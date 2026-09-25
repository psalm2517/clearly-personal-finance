import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';
import 'package:clearly/main.dart';
import 'package:clearly/theme/catppuccin.dart';
import 'package:clearly/widgets/add_transaction.dart';

void main() {
  late AppDatabase db;
  late HomebaseRepository repo;
  late Profile profile;

  // The dialog makes several database reads one after another; each needs
  // real time to finish and then a pump to resume the code awaiting it.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  // Database work is real async, which the widget tester's fake clock does
  // not drive — so it all goes through runAsync, not setUp.
  Future<void> open(WidgetTester tester) async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    repo = HomebaseRepository(db);
    await tester.runAsync(() async {
      final id = await repo.createProfile(
          ProfilesCompanion.insert(name: 'Owner', isAdmin: const Value(true)));
      profile = (await repo.profileById(id))!;
      await repo.upsertAccount(AccountsCompanion.insert(
          profileId: id,
          name: 'Checking',
          type: AccountType.checking,
          balanceCents: const Value(100000)));
      await repo.upsertAccount(AccountsCompanion.insert(
          profileId: id, name: 'Savings', type: AccountType.savings));
      await repo.upsertCard(CreditCardsCompanion.insert(
          profileId: id,
          name: 'Visa',
          creditLimitCents: 500000,
          balanceCents: const Value(20000)));
    });

    await tester.binding.setSurfaceSize(const Size(1000, 1400));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        loggedInProfileProvider.overrideWith((ref) => profile),
      ],
      child: MaterialApp(
        theme: themeFor(CatppuccinFlavor.mocha),
        home: Consumer(builder: (context, ref, _) {
          return Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showAddTransaction(context, ref),
                child: const Text('open'),
              ),
            ),
          );
        }),
      ),
    ));
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  testWidgets('every kind renders its own fields without error',
      (tester) async {
    await open(tester);
    expect(find.text('Description'), findsOneWidget);
    expect(find.text('Repeats'), findsOneWidget);

    await tester.tap(find.text('Income'));
    await tester.pumpAndSettle();
    expect(find.text('Deposited to (optional)'), findsOneWidget);

    await tester.tap(find.text('Transfer'));
    await tester.pumpAndSettle();
    expect(find.text('From'), findsOneWidget);
    expect(find.text('To'), findsOneWidget);

    await tester.tap(find.text('Payment'));
    await tester.pumpAndSettle();
    expect(find.text('Paying'), findsOneWidget);
    expect(find.text('Pay in full'), findsOneWidget);
    expect(find.text('Repeats'), findsNothing,
        reason: 'a payment cannot repeat');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Save stays disabled until there is an amount', (tester) async {
    await open(tester);
    final save = find.widgetWithText(FilledButton, 'Save');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(find.widgetWithText(TextField, 'Amount (\$)'), '12.50');
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull);
  });

  testWidgets('saving an expense records it and closes the dialog',
      (tester) async {
    await open(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Amount (\$)'), '12.50');
    await tester.enterText(find.widgetWithText(TextField, 'Description'), 'Lunch');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);

    final now = DateTime.now();
    final entries = await tester.runAsync(() => repo
        .watchBudgetForMonth(profileId: profile.id, month: DateTime(now.year, now.month))
        .first);
    expect(entries!.single.description, 'Lunch');
    expect(entries.single.amountCents, 1250);
    expect(find.text('Save'), findsNothing, reason: 'the dialog closed');
  });

  testWidgets('a rejected draft shows its reason and keeps what was typed',
      (tester) async {
    await open(tester);
    await tester.tap(find.text('Transfer'));
    await tester.pumpAndSettle();
    // Same account on both sides is refused by the repository.
    await tester.enterText(find.widgetWithText(TextField, 'Amount (\$)'), '5');
    await tester.pump();
    await tester.tap(find.widgetWithText(DropdownButtonFormField<int>, 'To'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Checking').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(tester);

    expect(find.text('the two accounts must be different'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget,
        reason: 'still open, nothing lost');
  });
}
