import 'package:flutter/material.dart';

import '../util/money.dart';

/// Wraps a line-chart [CustomPainter] with mouse hover: tracks the nearest
/// data point under the cursor, redraws the painter with a crosshair there
/// via [painterBuilder], and floats a small value/date tooltip above it.
class HoverLineChart extends StatefulWidget {
  const HoverLineChart({
    super.key,
    required this.height,
    required this.dates,
    required this.values,
    required this.painterBuilder,
  });

  final double height;
  final List<DateTime> dates;
  final List<int> values;
  final CustomPainter Function(int? hoverIndex) painterBuilder;

  @override
  State<HoverLineChart> createState() => _HoverLineChartState();
}

class _HoverLineChartState extends State<HoverLineChart> {
  int? _hoverIndex;

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  void _updateHover(double localX, double width) {
    if (widget.dates.length < 2) return;
    final ratio = (localX / width).clamp(0.0, 1.0);
    final index = (ratio * (widget.dates.length - 1)).round();
    if (index == _hoverIndex) return;
    setState(() => _hoverIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (widget.dates.length < 2) {
      return SizedBox(
        height: widget.height,
        width: double.infinity,
        child: CustomPaint(
          size: Size.infinite,
          painter: widget.painterBuilder(null),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final hover = _hoverIndex;
        // Tooltip x, clamped so it never runs off either edge of the chart.
        final tooltipWidth = 100.0;
        final rawX = hover == null
            ? 0.0
            : hover / (widget.dates.length - 1) * width;
        final tooltipLeft =
            (rawX - tooltipWidth / 2).clamp(0.0, width - tooltipWidth);
        return MouseRegion(
          onHover: (event) => _updateHover(event.localPosition.dx, width),
          onExit: (_) => setState(() => _hoverIndex = null),
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CustomPaint(
                  size: Size.infinite,
                  painter: widget.painterBuilder(hover),
                ),
                if (hover != null)
                  Positioned(
                    left: tooltipLeft,
                    top: -8,
                    width: tooltipWidth,
                    child: IgnorePointer(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: scheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.25),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              fmtCents(widget.values[hover]),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  fontFamily: 'monospace',
                                  fontWeight: FontWeight.w700,
                                  fontSize: 12),
                            ),
                            Text(
                              '${_months[widget.dates[hover].month - 1]} '
                              '${widget.dates[hover].day}',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: 10,
                                  color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// A smooth curve through [points] (Catmull-Rom converted to cubic Beziers),
/// instead of straight segments — a flowing line rather than an angular
/// polyline through the same data.
Path smoothPathThrough(List<Offset> points) {
  final path = Path();
  if (points.isEmpty) return path;
  path.moveTo(points[0].dx, points[0].dy);
  if (points.length == 1) return path;
  if (points.length == 2) {
    path.lineTo(points[1].dx, points[1].dy);
    return path;
  }
  for (var i = 0; i < points.length - 1; i++) {
    final p0 = i == 0 ? points[i] : points[i - 1];
    final p1 = points[i];
    final p2 = points[i + 1];
    final p3 = i + 2 < points.length ? points[i + 2] : p2;
    final cp1 = p1 + (p2 - p0) / 6;
    final cp2 = p2 - (p3 - p1) / 6;
    path.cubicTo(cp1.dx, cp1.dy, cp2.dx, cp2.dy, p2.dx, p2.dy);
  }
  return path;
}
