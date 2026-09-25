import 'package:flutter/material.dart';

/// Grouped income/expense bars by month.
class CashflowChart extends StatelessWidget {
  const CashflowChart({
    super.key,
    required this.data,
    required this.income,
    required this.expense,
    required this.label,
  });

  final List<({DateTime month, int incomeCents, int expenseCents})> data;
  final Color income;
  final Color expense;
  final Color label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _legend(income, 'Income'),
            const SizedBox(width: 16),
            _legend(expense, 'Expenses'),
          ],
        ),
        const SizedBox(height: 12),
        Expanded(
          child: CustomPaint(
            size: Size.infinite,
            painter: _CashflowPainter(
              data: data,
              income: income,
              expense: expense,
              label: label,
            ),
          ),
        ),
      ],
    );
  }

  Widget _legend(Color color, String text) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 6),
      Text(text, style: TextStyle(fontSize: 12, color: color)),
    ],
  );
}

class _CashflowPainter extends CustomPainter {
  _CashflowPainter({
    required this.data,
    required this.income,
    required this.expense,
    required this.label,
  });

  final List<({DateTime month, int incomeCents, int expenseCents})> data;
  final Color income;
  final Color expense;
  final Color label;

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
    if (data.isEmpty) return;
    final maxValue = data
        .expand((d) => [d.incomeCents, d.expenseCents])
        .fold(0, (a, b) => a > b ? a : b);
    if (maxValue == 0) return;

    const labelHeight = 20.0;
    final chartHeight = size.height - labelHeight;
    final slot = size.width / data.length;
    final barWidth = (slot * 0.30).clamp(6.0, 28.0);

    final gridLine = Paint()
      ..color = label.withValues(alpha: 0.1)
      ..strokeWidth = 1;
    const gridLines = 4;
    for (var i = 1; i < gridLines; i++) {
      final y = chartHeight * i / gridLines;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridLine);
    }

    for (var i = 0; i < data.length; i++) {
      final centre = slot * i + slot / 2;
      final d = data[i];

      void bar(int cents, Color color, double offset) {
        final h = cents / maxValue * (chartHeight - 8);
        final rect = RRect.fromRectAndCorners(
          Rect.fromLTWH(centre + offset, chartHeight - h, barWidth, h),
          topLeft: const Radius.circular(3),
          topRight: const Radius.circular(3),
        );
        canvas.drawRRect(rect, Paint()..color = color);
      }

      bar(d.incomeCents, income, -barWidth - 2);
      bar(d.expenseCents, expense, 2);

      final tp = TextPainter(
        text: TextSpan(
          text: _months[d.month.month - 1],
          style: TextStyle(color: label.withValues(alpha: 0.7), fontSize: 11),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(centre - tp.width / 2, size.height - labelHeight + 4),
      );
    }
  }

  @override
  bool shouldRepaint(_CashflowPainter old) =>
      old.data != data || old.income != income;
}
