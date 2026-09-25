import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/theme/catppuccin.dart';
import 'package:clearly/widgets/sankey_chart.dart';

Widget _host(Widget chart) => MaterialApp(
      theme: themeFor(CatppuccinFlavor.mocha),
      home: Scaffold(body: SizedBox(width: 600, height: 320, child: chart)),
    );

void main() {
  testWidgets('a surplus month builds without error', (tester) async {
    await tester.pumpWidget(_host(const IncomeSankeyChart(
      incomeByCategory: {'Paycheck': 300000},
      expenseByCategory: {'Rent': 120000, 'Food': 50000},
    )));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an overspent month builds without error', (tester) async {
    await tester.pumpWidget(_host(const IncomeSankeyChart(
      incomeByCategory: {'Paycheck': 83578},
      expenseByCategory: {'Rent': 100000, 'Food': 36000},
    )));
    expect(tester.takeException(), isNull);
  });

  testWidgets('spending with no income at all still builds', (tester) async {
    await tester.pumpWidget(_host(const IncomeSankeyChart(
      incomeByCategory: {},
      expenseByCategory: {'Food': 5000},
    )));
    expect(tester.takeException(), isNull);
    expect(find.text('Nothing to show yet'), findsNothing);
  });

  testWidgets('no data at all shows the empty state', (tester) async {
    await tester.pumpWidget(_host(const IncomeSankeyChart(
      incomeByCategory: {},
      expenseByCategory: {},
    )));
    expect(find.text('Nothing to show yet'), findsOneWidget);
  });

  testWidgets('many thin bars next to big ones build without error',
      (tester) async {
    await tester.pumpWidget(_host(const IncomeSankeyChart(
      incomeByCategory: {'Work': 78578, 'Other': 5000},
      expenseByCategory: {
        'Card payment - A': 19272,
        'Klarna': 15978,
        'Transfer': 15000,
        'BNPL': 2814,
        'FanDuel': 1000,
        'Tiny': 50,
      },
    )));
    expect(tester.takeException(), isNull);
  });
}
