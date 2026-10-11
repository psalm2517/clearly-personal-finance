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
