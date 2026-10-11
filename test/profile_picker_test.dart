import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';
import 'package:clearly/main.dart';
import 'package:clearly/screens/profile_picker.dart';
import 'package:clearly/theme/catppuccin.dart';

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  Future<ProviderContainer> mount(
      WidgetTester tester, AppDatabase db) async {
    final container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)]);
    addTearDown(container.dispose);
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: themeFor(CatppuccinFlavor.mocha),
        home: const ProfilePickerScreen(),
      ),
    ));
    await settle(tester);
    return container;
  }

  testWidgets('first run welcomes, names the app, and creates the profile',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = await mount(tester, db);

    expect(find.text('Clearly'), findsOneWidget);
    expect(find.text('See clearly.'), findsOneWidget);
    expect(find.text('Welcome to Clearly'), findsOneWidget);
    expect(find.text('Get started'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Sam');
    await tester.tap(find.text('Get started'));
    await settle(tester);

    final profile = container.read(loggedInProfileProvider);
    expect(profile?.name, 'Sam');
    expect(profile?.isAdmin, isTrue);

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a returning single profile gets a welcome back', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await tester.runAsync(() => HomebaseRepository(db).createProfile(
        ProfilesCompanion.insert(
            name: 'nick', isAdmin: const Value(true))));
    final container = await mount(tester, db);

    expect(find.text('Clearly'), findsOneWidget);
    expect(find.text('Welcome back'), findsOneWidget);
    expect(find.text('nick'), findsOneWidget);
    expect(find.text('N'), findsOneWidget, reason: 'initial in the avatar');

    await tester.tap(find.text('nick'));
    await settle(tester);
    expect(container.read(loggedInProfileProvider)?.name, 'nick');

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
  });
}
