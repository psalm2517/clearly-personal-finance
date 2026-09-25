import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';
import 'package:clearly/main.dart';
import 'package:clearly/screens/nav.dart';
import 'package:clearly/screens/shell.dart';
import 'package:clearly/theme/catppuccin.dart';

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
  }

  testWidgets('every sidebar page opens without error, and tabbed pages '
      'expose their tabs', (tester) async {
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
          name: 'Checking',
          type: AccountType.checking,
          balanceCents: const Value(100000)));
    });

    await tester.binding.setSurfaceSize(const Size(1400, 1000));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        loggedInProfileProvider.overrideWith((ref) => profile),
      ],
      child: MaterialApp(
        theme: themeFor(CatppuccinFlavor.mocha),
        home: const AppShell(),
      ),
    ));
    await settle(tester);

    // The sidebar has exactly the seven places, and Add is always there.
    for (final d in Dest.values) {
      expect(find.text(d.title), findsWidgets, reason: d.title);
    }
    expect(find.widgetWithText(FilledButton, 'Add'), findsOneWidget);

    for (final d in Dest.values) {
      await tester.tap(find.descendant(
          of: find.byType(NavigationRail), matching: find.text(d.title)));
      await settle(tester);
      expect(tester.takeException(), isNull, reason: 'opening ${d.title}');
    }

    // Tabbed pages: Accounts has Goals now, Recurring has all five.
    await tester.tap(find.descendant(
        of: find.byType(NavigationRail), matching: find.text('Accounts')));
    await settle(tester);
    Finder tab(String t) =>
        find.descendant(of: find.byType(TabBar), matching: find.text(t));
    expect(tab('Goals'), findsOneWidget);
    expect(tab('Transfers'), findsNothing,
        reason: 'scheduled transfers live under Recurring now');

    await tester.tap(find.descendant(
        of: find.byType(NavigationRail), matching: find.text('Recurring')));
    await settle(tester);
    Finder tabFinder(String t) =>
        find.descendant(of: find.byType(TabBar), matching: find.text(t));
    for (final tab in ['Upcoming', 'Bills', 'Paychecks', 'Transfers', 'Other']) {
      expect(tabFinder(tab), findsOneWidget, reason: tab);
    }
    expect(tester.takeException(), isNull);

    // Unmount and let the database streams' cleanup timers run out.
    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
  });
}
