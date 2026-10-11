import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/database.dart';
import 'package:clearly/data/repository.dart';
import 'package:clearly/data/simplefin.dart';
import 'package:clearly/main.dart';
import 'package:clearly/screens/bank_sync.dart';
import 'package:clearly/theme/catppuccin.dart';

class _Bridge implements SimpleFinTransport {
  @override
  Future<({int status, String body})> send(String method, Uri url,
      {Map<String, String> headers = const {}}) async {
    if (method == 'POST') {
      return (status: 200, body: 'https://u:p@bridge.test/simplefin');
    }
    return (
      status: 200,
      body: jsonEncode({
        'errlist': [],
        'accounts': [
          {
            'id': 'CHK',
            'name': 'Everyday',
            'balance': '250.00',
            'transactions': [
              {
                'id': 't1',
                'posted': DateTime.now().millisecondsSinceEpoch ~/ 1000,
                'amount': '-5.00',
                'description': 'COFFEE',
              }
            ],
          }
        ],
      }),
    );
  }
}

void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
    }
  }

  testWidgets('connect with a token, then add a feed account and sync',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = HomebaseRepository(db);
    late Profile profile;
    await tester.runAsync(() async {
      final id = await repo.createProfile(
          ProfilesCompanion.insert(name: 'Owner', isAdmin: const Value(true)));
      profile = (await repo.profileById(id))!;
    });

    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        loggedInProfileProvider.overrideWith((ref) => profile),
        simpleFinClientProvider
            .overrideWithValue(SimpleFinClient(transport: _Bridge())),
      ],
      child: MaterialApp(
        theme: themeFor(CatppuccinFlavor.mocha),
        home: const Scaffold(body: SingleChildScrollView(child: BankSyncSection())),
      ),
    ));
    await settle(tester);

    expect(find.text('Connect SimpleFIN'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await settle(tester);
    await tester.enterText(
        find.byType(TextField),
        base64.encode(utf8.encode('https://bridge.test/simplefin/claim/X')));
    await tester.tap(find.widgetWithText(FilledButton, 'Connect').last);
    await settle(tester);

    // The feed account is listed and waiting for a decision.
    expect(find.text('Everyday'), findsOneWidget);
    expect(find.text('Needs review'), findsOneWidget);

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600)); // menu animation
    await tester.tap(find.text('Add as checking'));
    await settle(tester);

    expect(find.text('Account'), findsOneWidget);
    final accounts = await tester.runAsync(() => db.select(db.accounts).get());
    expect(accounts!.single.name, 'Everyday');
    expect(accounts.single.balanceCents, 25000);
    final entries =
        await tester.runAsync(() => db.select(db.budgetEntries).get());
    expect(entries!.single.description, 'COFFEE');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
  });

  testWidgets('a malformed token is rejected before anything is sent',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = HomebaseRepository(db);
    late Profile profile;
    await tester.runAsync(() async {
      final id = await repo.createProfile(
          ProfilesCompanion.insert(name: 'Owner', isAdmin: const Value(true)));
      profile = (await repo.profileById(id))!;
    });
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        loggedInProfileProvider.overrideWith((ref) => profile),
        simpleFinClientProvider
            .overrideWithValue(SimpleFinClient(transport: _Bridge())),
      ],
      child: MaterialApp(
        theme: themeFor(CatppuccinFlavor.mocha),
        home: const Scaffold(body: SingleChildScrollView(child: BankSyncSection())),
      ),
    ));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await settle(tester);
    await tester.enterText(find.byType(TextField), 'not a token');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect').last);
    await settle(tester);
    expect(find.textContaining('does not look like'), findsOneWidget);
    expect(find.text('Connect SimpleFIN'), findsWidgets);
    expect(await tester.runAsync(() => db.select(db.simpleFinConnections).get()),
        isEmpty);

    await tester.pumpWidget(const SizedBox());
    await settle(tester);
    await tester.pump(const Duration(seconds: 2));
  });
}
