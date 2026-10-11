import 'package:flutter/material.dart';

/// Shows one of several pages and keeps the others alive.
///
/// A page is built the first time it is shown and then never rebuilt or
/// torn down, so going back to it is instant, with its scroll position and
/// data already there. Switching fades the incoming page in briefly rather
/// than cutting or sliding, which is what makes moving between sections
/// feel smooth instead of re-loading each time.
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

class _LazyIndexedStackState extends State<LazyIndexedStack>
    with SingleTickerProviderStateMixin {
  late final _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 180),
    value: 1,
  );
  late final _opacity = Tween<double>(
    begin: 0.3,
    end: 1,
  ).animate(CurvedAnimation(parent: _fade, curve: Curves.easeOut));
  final _built = <int>{};

  @override
  void initState() {
    super.initState();
    _built.add(widget.index);
  }

  @override
  void didUpdateWidget(LazyIndexedStack old) {
    super.didUpdateWidget(old);
    _built.add(widget.index);
    if (old.index != widget.index) _fade.forward(from: 0);
  }

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: IndexedStack(
        index: widget.index,
        sizing: StackFit.expand,
        children: [
          for (var i = 0; i < widget.builders.length; i++)
            _built.contains(i)
                ? Builder(builder: widget.builders[i])
                : const SizedBox.shrink(),
        ],
      ),
    );
  }
}
