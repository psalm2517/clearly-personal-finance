import 'package:flutter/material.dart';

import '../widgets/lazy_indexed_stack.dart';
import 'accounts.dart';
import 'accounts_overview.dart';
import 'cards.dart';
import 'loans.dart';
import 'goals.dart';

/// Accounts, Cards and Loans used to be three separate sidebar entries.
/// Grouping them under one "Accounts" destination with tabs cuts down the
/// nav rail, and a net-worth summary above the tabs gives the combined
/// picture that used to only exist on the Dashboard. The Overview tab is
/// that picture; the Cash, Cards, Loans and Goals tabs keep their own logic
/// (editing, payoff calculators, statement cycles) unchanged.
class AccountsHubScreen extends StatefulWidget {
  const AccountsHubScreen({super.key});

  @override
  State<AccountsHubScreen> createState() => _AccountsHubScreenState();
}

class _AccountsHubScreenState extends State<AccountsHubScreen>
    with SingleTickerProviderStateMixin {
  late final _controller = TabController(
    length: 5,
    vsync: this,
    animationDuration: Duration.zero,
  );

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
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
            // A pill-shaped segmented control, not Material's default
            // underline TabBar, for switching between a handful of views.
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
                  Tab(text: 'Overview'),
                  Tab(text: 'Cash'),
                  Tab(text: 'Cards'),
                  Tab(text: 'Loans'),
                  Tab(text: 'Goals'),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => LazyIndexedStack(
              index: _controller.index,
              builders: [
                (_) => AccountsOverview(onOpenTab: _controller.animateTo),
                (_) => const AccountsScreen(),
                (_) => const CardsScreen(),
                (_) => const LoansScreen(),
                (_) => const GoalsScreen(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
