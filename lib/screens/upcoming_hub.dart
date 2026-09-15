import 'package:flutter/material.dart';

import 'recurring.dart';
import 'upcoming.dart';

/// Groups the merged "what's coming" list with managing the schedules that
/// feed it — the same tabbed-hub shape as Accounts (Cash/Cards/Loans grouped
/// under one destination with a shared header).
class UpcomingHubScreen extends StatefulWidget {
  const UpcomingHubScreen({super.key});

  @override
  State<UpcomingHubScreen> createState() => _UpcomingHubScreenState();
}

class _UpcomingHubScreenState extends State<UpcomingHubScreen>
    with SingleTickerProviderStateMixin {
  late final _controller = TabController(length: 2, vsync: this);

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
                  Tab(text: 'Recurring'),
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
              RecurringTransactionsScreen(),
            ],
          ),
        ),
      ],
    );
  }
}
