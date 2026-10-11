import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/widgets/lazy_indexed_stack.dart';

class _Counter extends StatefulWidget {
  const _Counter(this.label, this.onBuild);
  final String label;
  final VoidCallback onBuild;
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int taps = 0;
  @override
  Widget build(BuildContext context) {
    widget.onBuild();
    return TextButton(
      onPressed: () => setState(() => taps++),
      child: Text('${widget.label}:$taps'),
    );
  }
}

void main() {
  _themeTests();
  testWidgets('pages build on first view and keep their state afterwards',
      (tester) async {
    var builtB = 0;
    Widget host(int index) => MaterialApp(
          home: LazyIndexedStack(index: index, builders: [
            (_) => _Counter('A', () {}),
            (_) => _Counter('B', () => builtB++),
          ]),
        );

    await tester.pumpWidget(host(0));
    expect(builtB, 0, reason: 'a page nobody has opened is never built');

    await tester.tap(find.text('A:0'));
    await tester.pump();
    expect(find.text('A:1'), findsOneWidget);

    await tester.pumpWidget(host(1));
    await tester.pumpAndSettle();
    expect(builtB, greaterThan(0));
    expect(find.text('B:0'), findsOneWidget);

    // Back to A: its state survived, it was not rebuilt from scratch.
    await tester.pumpWidget(host(0));
    await tester.pumpAndSettle();
    expect(find.text('A:1'), findsOneWidget);
  });
}

void _themeTests() {
  testWidgets('hidden pages are let go on a theme change, not rebuilt',
      (tester) async {
    var buildsA = 0;
    Widget host(int index, ThemeData theme) => MaterialApp(
          theme: theme,
          themeAnimationDuration: Duration.zero,
          home: LazyIndexedStack(index: index, builders: [
            (c) {
              buildsA++;
              return Text('A ${Theme.of(c).brightness.name}');
            },
            (c) => Text('B ${Theme.of(c).brightness.name}'),
          ]),
        );
    final light = ThemeData(brightness: Brightness.light);
    final dark = ThemeData(brightness: Brightness.dark);

    await tester.pumpWidget(host(0, light));
    await tester.pumpWidget(host(1, light)); // B is built, A is hidden
    expect(find.text('B light'), findsOneWidget);
    final a0 = buildsA;

    await tester.pumpWidget(host(1, dark));
    expect(find.text('B dark'), findsOneWidget);
    expect(buildsA, a0,
        reason: 'a hidden page is not rebuilt for a theme change');

    await tester.pumpWidget(host(0, dark));
    expect(find.text('A dark'), findsOneWidget,
        reason: 'it is built fresh, in the new theme, when shown again');
  });
}
