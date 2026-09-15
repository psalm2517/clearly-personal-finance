import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repository.dart';
import '../main.dart';
import '../util/money.dart';
import '../widgets/common.dart';

IconData _kindIcon(UpcomingKind kind) => switch (kind) {
      UpcomingKind.bill => Icons.receipt_long_outlined,
      UpcomingKind.paycheck => Icons.payments_outlined,
      UpcomingKind.transfer => Icons.sync_alt_outlined,
      UpcomingKind.recurring => Icons.autorenew,
    };

String _kindLabel(UpcomingKind kind) => switch (kind) {
      UpcomingKind.bill => 'Bill',
      UpcomingKind.paycheck => 'Paycheck',
      UpcomingKind.transfer => 'Transfer',
      UpcomingKind.recurring => 'Recurring',
    };

/// Everything Clearly already knows is coming — bills, paychecks,
/// transfers and general recurring transactions — merged into one
/// chronological list instead of checking four separate screens.
class UpcomingScreen extends ConsumerStatefulWidget {
  const UpcomingScreen({super.key});

  @override
  ConsumerState<UpcomingScreen> createState() => _UpcomingScreenState();
}

class _UpcomingScreenState extends ConsumerState<UpcomingScreen> {
  int _days = 30;

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final profileId = ref.watch(activeProfileProvider)!.id;
    final scheme = Theme.of(context).colorScheme;

    return FutureBuilder<List<UpcomingItem>>(
      future: repo.upcomingItems(profileId: profileId, days: _days),
      builder: (context, snap) {
        final items = snap.data ?? [];

        return ListView(
          padding: kPagePadding,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                SectionHeader('Upcoming',
                    icon: Icons.upcoming_outlined,
                    info: const InfoButton(
                      title: 'Upcoming',
                      body: [
                        'Every bill due, paycheck landing, recurring '
                            'transfer, and general recurring transaction '
                            'in the window below, in one chronological '
                            'list.',
                        'This is the same data the projected cash balance '
                            'on the Dashboard is built from — this view '
                            'just shows what each occurrence actually is, '
                            'rather than the running total.',
                      ],
                    )),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 7, label: Text('7d')),
                    ButtonSegment(value: 30, label: Text('30d')),
                    ButtonSegment(value: 90, label: Text('90d')),
                  ],
                  selected: {_days},
                  onSelectionChanged: (s) => setState(() => _days = s.first),
                ),
              ],
            ),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: EmptyState(
                  icon: Icons.upcoming_outlined,
                  title: 'Nothing coming up',
                  message: 'Bills, paychecks, transfers and recurring '
                      'transactions in this window will show up here.',
                ),
              )
            else
              Card(
                child: Column(
                  children: [
                    for (final item in items)
                      ListTile(
                        leading: Icon(_kindIcon(item.kind),
                            color: item.amountCents >= 0
                                ? scheme.primary
                                : scheme.onSurfaceVariant),
                        title: Text(item.label),
                        subtitle: Text(
                            '${_fmtDate(item.date)} • ${_kindLabel(item.kind)}'),
                        trailing: Text(
                          '${item.amountCents >= 0 ? '+' : '-'}'
                          '${fmtCents(item.amountCents.abs())}',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                            color: item.amountCents >= 0
                                ? scheme.primary
                                : null,
                          ),
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

  static String _fmtDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[d.month - 1]} ${ordinalDay(d.day)}, ${d.year}';
  }
}
