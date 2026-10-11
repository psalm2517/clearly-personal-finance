import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';
import 'package:clearly/main.dart';
import 'package:clearly/screens/accounts_hub.dart';
import 'package:clearly/theme/catppuccin.dart';

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
  }

  testWidgets('overview groups assets and debts, totals them, and opens the '
      'matching tab', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = HomebaseRepository(db);
    late Profile profile;
    await tester.runAsync(() async {
      final id = await repo.createProfile(
          ProfilesCompanion.insert(name: 'Owner', isAdmin: const Value(true)));
      profile = (await repo.profileById(id))!;
      await repo.upsertAccount(AccountsCompanion.insert(
          profileId: id,
          name: 'Everyday',
          type: AccountType.checking,
          balanceCents: const Value(250000)));
      await repo.upsertAccount(AccountsCompanion.insert(
          profileId: id,
          name: 'Index fund',
          type: AccountType.investment,
          balanceCents: const Value(750000)));
      await db.into(db.loans).insert(LoansCompanion.insert(
          profileId: id,
          name: 'Car loan',
          balanceCents: 400000,
          originalAmountCents: 900000));
    });

    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        loggedInProfileProvider.overrideWith((ref) => profile),
      ],
      child: MaterialApp(
        theme: themeFor(CatppuccinFlavor.mocha),
        home: const Scaffold(body: AccountsHubScreen()),
      ),
    ));
    await settle(tester);

    // Groups, each with its own total.
    expect(find.text('Cash'), findsWidgets);
    expect(find.text('Investments'), findsWidgets);
    expect(find.text('Loans'), findsWidgets);
    expect(find.text('Everyday'), findsOneWidget);
    expect(find.text('Car loan'), findsOneWidget);
    // Net worth = 2,500 + 7,500 - 4,000.
    expect(find.textContaining('6,000', findRichText: true), findsWidgets);

    // The summary can flip to percentages.
    await tester.tap(find.text('Percent'));
    await settle(tester);
    expect(find.text('25%'), findsOneWidget); // cash is 2,500 of 10,000

    // Tapping a loan row opens the Loans tab, which has its own screen.
    await tester.tap(find.text('Car loan'));
    await settle(tester);
    expect(find.text('Car loan'), findsWidgets);
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
  });
}
