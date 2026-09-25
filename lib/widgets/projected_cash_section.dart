import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../main.dart';
import '../util/money.dart';
import 'common.dart';
import 'hover_line_chart.dart';

/// The projected cash balance chart with a 30/60/90-day window toggle and a
/// warning banner if the projection ever dips negative in that window.
class ProjectedCashBalanceSection extends ConsumerStatefulWidget {
  const ProjectedCashBalanceSection(
      {super.key, required this.profileId, required this.scheme});

  final int profileId;
  final ColorScheme scheme;

  @override
  ConsumerState<ProjectedCashBalanceSection> createState() =>
      _ProjectedCashBalanceSectionState();
}

class _ProjectedCashBalanceSectionState
    extends ConsumerState<ProjectedCashBalanceSection> {
  int _days = 60;

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final scheme = widget.scheme;
    return FutureBuilder<List<({DateTime date, int balanceCents})>>(
      future: repo.projectCashFlow(
          profileId: widget.profileId, days: _days),
      builder: (context, snap) {
        final points = snap.data ?? [];
        if (points.isEmpty) return const SizedBox.shrink();
        final start = points.first.balanceCents;
        final end = points.last.balanceCents;
        final lowestPoint = points
            .reduce((a, b) => a.balanceCents < b.balanceCents ? a : b);
        final lowest = lowestPoint.balanceCents;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: SectionHeader(
                    'Projected cash balance',
                    icon: Icons.trending_up,
                    info: const InfoButton(
                      title: 'Projected cash balance',
                      body: [
                        'A projection of your balance, not your flow — see '
                            '"Income vs spending" below for money in versus '
                            'out by month. This is where checking, savings and '
                            'cash is headed, not a prediction of unplanned '
                            'spending, just what Clearly already knows is '
                            'coming: scheduled paychecks, bills, recurring '
                            'transactions, and any recurring transfer that '
                            'actually moves money into or out of cash.',
                        'Investment, retirement and other account types are '
                            'left out, the same way the Accounts screen '
                            'splits Cash from Assets — this is about money '
                            'you can actually spend. A transfer between two '
                            'cash accounts doesn\'t change this number '
                            'either, since the total stays the same either '
                            'way.',
                        'Card and loan payments, and anything not entered '
                            'on a schedule, are not included. This gets '
                            'more accurate the more of your recurring money '
                            'is set up in Clearly.',
                      ],
                    ),
                  ),
                ),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 30, label: Text('30d')),
                    ButtonSegment(value: 60, label: Text('60d')),
                    ButtonSegment(value: 90, label: Text('90d')),
                  ],
                  selected: {_days},
                  onSelectionChanged: (s) => setState(() => _days = s.first),
                ),
              ],
            ),
            if (lowest < 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Card(
                  color: scheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        Icon(Icons.warning_amber_outlined,
                            color: scheme.onErrorContainer),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Projected to go ${fmtCents(lowest)} on '
                            '${lowestPoint.date.month}/${lowestPoint.date.day}'
                            ' if nothing changes.',
                            style: TextStyle(color: scheme.onErrorContainer),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MoneyText(
                    fmtCents(end),
                    style: Theme.of(context).textTheme.headlineMedium
                        ?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontFamily: 'monospace',
                        ),
                  ),
                  const SizedBox(height: 4),
                  Pill(
                    '${end >= start ? '+' : ''}'
                    '${fmtCents(end - start)} projected over '
                    '${points.length - 1} days'
                    '${lowest < 0 ? ' • dips negative' : ''}',
                    color: lowest < 0
                        ? scheme.error
                        : end >= start
                        ? scheme.primary
                        : scheme.error,
                  ),
                  const SizedBox(height: 16),
                  HoverLineChart(
                    height: 140,
                    dates: [for (final p in points) p.date],
                    values: [for (final p in points) p.balanceCents],
                    painterBuilder: (hover) => _ProjectionChartPainter(
                      points: points,
                      line: scheme.primary,
                      negative: scheme.error,
                      grid: scheme.outline,
                      hoverIndex: hover,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// A forward-looking cash balance line — same visual language as the net
/// worth chart (grid, dashed zero baseline, smooth curve, soft fill) so the
/// two read as one family rather than two unrelated widgets.
class _ProjectionChartPainter extends CustomPainter {
  _ProjectionChartPainter({
    required this.points,
    required this.line,
    required this.negative,
    required this.grid,
    this.hoverIndex,
  });

  final List<({DateTime date, int balanceCents})> points;
  final Color line;
  final Color negative;
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
    if (points.length < 2) return;
    const labelHeight = 20.0;
    final chartHeight = size.height - labelHeight;

    final values = points.map((p) => p.balanceCents).toList();
    var minValue = values.reduce((a, b) => a < b ? a : b);
    var maxValue = values.reduce((a, b) => a > b ? a : b);
    if (minValue > 0) minValue = 0;
    if (maxValue < 0) maxValue = 0;
    final range = (maxValue - minValue) == 0 ? 1 : (maxValue - minValue);

    double yFor(int cents) =>
        chartHeight - ((cents - minValue) / range) * (chartHeight - 8) - 4;
    double xFor(int i) => i * size.width / (values.length - 1);

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

    final zeroY = yFor(0);
    final dash = Paint()
      ..color = grid.withValues(alpha: 0.6)
      ..strokeWidth = 1;
    for (var x = 0.0; x < size.width; x += 8) {
      canvas.drawLine(Offset(x, zeroY), Offset(x + 4, zeroY), dash);
    }

    final offsets = [
      for (var i = 0; i < values.length; i++) Offset(xFor(i), yFor(values[i])),
    ];
    final path = smoothPathThrough(offsets);

    final ending = values.last >= values.first ? line : negative;
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

    canvas.drawCircle(
      Offset(xFor(values.length - 1), yFor(values.last)),
      4,
      Paint()..color = ending,
    );

    if (hoverIndex != null && hoverIndex! < values.length) {
      final hx = xFor(hoverIndex!);
      final hy = yFor(values[hoverIndex!]);
      canvas.drawLine(
        Offset(hx, 0),
        Offset(hx, chartHeight),
        Paint()
          ..color = grid.withValues(alpha: 0.6)
          ..strokeWidth = 1,
      );
      canvas.drawCircle(Offset(hx, hy), 5, Paint()..color = grid);
      canvas.drawCircle(Offset(hx, hy), 3, Paint()..color = ending);
    }

    void drawText(String text, Offset at, {bool right = false}) {
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: TextStyle(color: grid, fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, at - (right ? Offset(tp.width, 0) : Offset.zero));
    }

    final lastDate = points.last.date;
    drawText('Today', Offset(0, size.height - labelHeight + 4));
    drawText(
      '${_months[lastDate.month - 1]} ${lastDate.day}',
      Offset(size.width, size.height - labelHeight + 4),
      right: true,
    );
  }

  @override
  bool shouldRepaint(_ProjectionChartPainter old) =>
      old.points != points ||
      old.line != line ||
      old.hoverIndex != hoverIndex;
}
