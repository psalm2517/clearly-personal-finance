import 'package:flutter/material.dart';

/// Shows one of several pages and keeps the others alive.
///
/// A page is built the first time it is shown and then kept, so going back
/// to it is instant, with its scroll position and data already there. The
/// switch itself is immediate: no slide, and no fade.
///
/// Pages that are not showing cost almost nothing: they are [Offstage], so
/// they are neither laid out nor painted, and their tickers are muted.
///
/// Changing the theme is the one time they are let go. Every page reads the
/// theme, so keeping them would rebuild and re-query all of them for a
/// change nobody can see. They are dropped instead and built fresh, in the
/// new theme, the next time they are shown.
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
  /// The subtree last built for each page that has been shown. Reusing the
  /// same widget instance while a page is hidden is what stops Flutter
  /// rebuilding it: an identical widget is skipped outright.
  final _pages = <int, Widget>{};
  ThemeData? _theme;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_theme != null && _theme != theme) {
      _pages.removeWhere((i, _) => i != widget.index);
    }
    _theme = theme;

    // The visible page is rebuilt with everything else; hidden ones keep
    // the instance they had.
    _pages[widget.index] = Builder(builder: widget.builders[widget.index]);

    return Stack(
      fit: StackFit.expand,
      children: [
        for (var i = 0; i < widget.builders.length; i++)
          if (!_pages.containsKey(i))
            const SizedBox.shrink()
          else
            Offstage(
              offstage: i != widget.index,
              child: TickerMode(
                enabled: i == widget.index,
                child: _pages[i]!,
              ),
            ),
      ],
    );
  }
}
