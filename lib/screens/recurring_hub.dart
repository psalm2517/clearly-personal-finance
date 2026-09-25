import 'package:flutter/material.dart';

import 'bills.dart';
import 'paychecks.dart';
import 'recurring.dart';
import 'transfers.dart';
import 'upcoming.dart';

/// Everything that repeats, in one place: what's coming up next, then each
/// kind of thing that repeats — bills, paychecks, scheduled transfers, and
/// anything else on a schedule. Add anything new with the Add button.
class RecurringHubScreen extends StatefulWidget {
  const RecurringHubScreen({super.key});

  @override
  State<RecurringHubScreen> createState() => _RecurringHubScreenState();
}

class _RecurringHubScreenState extends State<RecurringHubScreen>
    with SingleTickerProviderStateMixin {
  late final _controller = TabController(length: 5, vsync: this);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(24),
              ),
              child: TabBar(
                controller: _controller,
                isScrollable: true,
                tabAlignment: TabAlignment.start,
                dividerColor: Colors.transparent,
                indicatorSize: TabBarIndicatorSize.tab,
                indicator: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(20),
                ),
                labelColor: scheme.onSurface,
                unselectedLabelColor: scheme.onSurfaceVariant,
                labelStyle: const TextStyle(fontWeight: FontWeight.w600),
                tabs: const [
                  Tab(text: 'Upcoming'),
                  Tab(text: 'Bills'),
                  Tab(text: 'Paychecks'),
                  Tab(text: 'Transfers'),
                  Tab(text: 'Other'),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _controller,
            children: const [
              UpcomingScreen(),
              BillsScreen(),
              PaychecksScreen(),
              TransfersScreen(),
              RecurringTransactionsScreen(),
            ],
          ),
        ),
      ],
    );
  }
}
