import 'package:flutter/material.dart';

import '../data/database.dart';
import 'hover_line_chart.dart';

/// The net worth trend line with hover tooltip, shared by the Dashboard and
/// the Accounts overview so both draw the same thing from the same history.
class NetWorthChart extends StatelessWidget {
  const NetWorthChart({super.key, required this.history, this.height = 160});

  final List<NetWorthSnapshot> history;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return HoverLineChart(
      height: height,
      dates: [for (final h in history) h.date],
      values: [for (final h in history) h.netWorthCents],
      painterBuilder: (hover) => NetWorthChartPainter(
        history: history,
        line: scheme.primary,
        negative: scheme.error,
        label: scheme.onSurface,
        grid: scheme.outline,
        hoverIndex: hover,
      ),
    );
  }
}

/// Net worth over time. Handles negative values by anchoring the scale to
/// include zero and drawing a dashed baseline there.
class NetWorthChartPainter extends CustomPainter {
  NetWorthChartPainter({
    required this.history,
    required this.line,
    required this.negative,
    required this.label,
    required this.grid,
    this.hoverIndex,
  });

  final List<NetWorthSnapshot> history;
  final Color line;
  final Color negative;
  final Color label;
  final Color grid;
  final int? hoverIndex;

  static const _months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];

  @override
  void paint(Canvas canvas, Size size) {
    if (history.length < 2) return;
    const labelHeight = 20.0;
    final chartHeight = size.height - labelHeight;

    final values = history.map((s) => s.netWorthCents).toList();
    // Always include zero so the baseline is meaningful.
    var minValue = values.reduce((a, b) => a < b ? a : b);
    var maxValue = values.reduce((a, b) => a > b ? a : b);
    if (minValue > 0) minValue = 0;
    if (maxValue < 0) maxValue = 0;
    final range = (maxValue - minValue) == 0 ? 1 : (maxValue - minValue);

    double yFor(int cents) =>
        chartHeight - ((cents - minValue) / range) * (chartHeight - 8) - 4;
    double xFor(int i) => history.length == 1
        ? size.width / 2
        : i * size.width / (history.length - 1);

    // A real graph-paper grid — horizontal and vertical — fills what would
    // otherwise be dead space under the line with a sense of scale, the
    // way most technical charting tools look by default.
    final gridLine = Paint()
      ..color = grid.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    const rows = 4;
    for (var i = 1; i < rows; i++) {
      final y = chartHeight * i / rows;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridLine);
    }
    const columns = 8;
    for (var i = 1; i < columns; i++) {
      final x = size.width * i / columns;
      canvas.drawLine(Offset(x, 0), Offset(x, chartHeight), gridLine);
    }

    // Zero baseline, dashed.
    final zeroY = yFor(0);
    final dash = Paint()
      ..color = grid.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, zeroY), Offset(x + 4, zeroY), dash);
    }

    final points = [
      for (var i = 0; i < values.length; i++) Offset(xFor(i), yFor(values[i])),
    ];
    final path = smoothPathThrough(points);

    // Soft fill under the line, tinted by whether it ends up or down.
    final ending = values.last >= 0 ? line : negative;
    final fill = Path.from(path)
      ..lineTo(xFor(values.length - 1), zeroY)
      ..lineTo(xFor(0), zeroY)
      ..close();
    canvas.drawPath(fill, Paint()..color = ending.withValues(alpha: 0.12));

    canvas.drawPath(
      path,
      Paint()
        ..color = ending
        ..strokeWidth = 2.5
        ..style = PaintingStyle.stroke,
    );

    // End point emphasised with its value.
    final lastX = xFor(values.length - 1);
    final lastY = yFor(values.last);
    canvas.drawCircle(Offset(lastX, lastY), 4, Paint()..color = ending);

    if (hoverIndex != null && hoverIndex! < values.length) {
      final hx = xFor(hoverIndex!);
      final hy = yFor(values[hoverIndex!]);
      canvas.drawLine(
        Offset(hx, 0),
        Offset(hx, chartHeight),
        Paint()
          ..color = label.withValues(alpha: 0.4)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(Offset(hx, hy), 5, Paint()..color = label);
      canvas.drawCircle(Offset(hx, hy), 3, Paint()..color = ending);
    }

    void drawText(String text, Offset at, {Color? color, bool right = false}) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: color ?? label, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at - (right ? Offset(tp.width, 0) : Offset.zero));
    }

    // The end value has its own big hero display above the chart now, so
    // the chart itself stays uncluttered — just the line and its dates.

    // First and last dates along the bottom.
    final firstDate = history.first.date;
    final lastDate = history.last.date;
    drawText(
      '${_months[firstDate.month - 1]} ${firstDate.day}',
      Offset(0, size.height - labelHeight + 4),
    );
    drawText(
      '${_months[lastDate.month - 1]} ${lastDate.day}',
      Offset(size.width, size.height - labelHeight + 4),
      right: true,
    );
  }

  @override
  bool shouldRepaint(NetWorthChartPainter old) =>
      old.history != history ||
      old.line != line ||
      old.hoverIndex != hoverIndex;
}
