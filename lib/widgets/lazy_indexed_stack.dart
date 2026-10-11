import 'package:flutter/material.dart';

/// Shows one of several pages and keeps the others alive.
///
/// A page is built the first time it is shown and then never rebuilt or
/// torn down, so going back to it is instant, with its scroll position and
/// data already there. The switch itself is immediate: no slide, and no
/// fade, because a fade dims the page mid-switch and reads as flicker.
class LazyIndexedStack extends StatefulWidget {
  const LazyIndexedStack({
    super.key,
    required this.index,
    required this.builders,
  });

  final int index;
  final List<WidgetBuilder> builders;

  @override
  State<LazyIndexedStack> createState() => _LazyIndexedStackState();
}

class _LazyIndexedStackState extends State<LazyIndexedStack> {
  final _built = <int>{};

  @override
  Widget build(BuildContext context) {
    _built.add(widget.index);
    return IndexedStack(
      index: widget.index,
      sizing: StackFit.expand,
      children: [
        for (var i = 0; i < widget.builders.length; i++)
          _built.contains(i)
              ? Builder(builder: widget.builders[i])
              : const SizedBox.shrink(),
      ],
    );
  }
}
