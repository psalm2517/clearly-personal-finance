import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../main.dart';
import '../widgets/cashflow_chart.dart';
import '../util/money.dart';
import '../widgets/common.dart';
import '../widgets/projected_cash_section.dart';
import '../widgets/sankey_chart.dart';

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'
];

/// Where money came from and where it went, and where your cash is headed:
/// the month's flow, income against spending over six months, and the
/// projected balance with its warning. One page for "cash flow", instead of
/// pieces of it spread over the Budget and Dashboard screens.
class CashFlowScreen extends ConsumerStatefulWidget {
  const CashFlowScreen({super.key});

  @override
  ConsumerState<CashFlowScreen> createState() => _CashFlowScreenState();
}

class _CashFlowScreenState extends ConsumerState<CashFlowScreen> {
  var _month = DateTime(DateTime.now().year, DateTime.now().month);

  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _month.year == now.year && _month.month == now.month;
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final profileId = ref.watch(activeProfileProvider)!.id;
    final scheme = Theme.of(context).colorScheme;

    return ListView(
      padding: kPagePadding,
      children: [
        SectionHeader('Where it went',
            icon: Icons.alt_route,
            info: const InfoButton(
              title: 'Where it went',
              body: [
                'What came in this month is on the left, and where it went is '
                    'on the right: your spending by category, transfers to '
                    'your other accounts, and loan payments.',
                'Only money that really went somewhere is drawn on the '
                    'right. If the middle bar is taller than what flows out '
                    'of it, the note underneath says how much has not been '
                    'spent or moved yet. It is not counted as savings.',
                'Spending is counted when you make it, including on a card. '
                    'A card payment is not drawn separately, because it '
                    'settles purchases that are already counted.',
                'If more went out than came in, the gap shows on the left as '
                    'a Shortfall: money that came from savings from earlier '
                    'months or from borrowing, not from this month\'s '
                    'income.',
              ],
            )),
        _monthBar(context),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: StreamBuilder<List<dynamic>>(
                stream: combineLatest<dynamic>([
                  repo.watchBudgetForMonth(profileId: profileId, month: _month),
                  repo.watchSplitsByEntry(profileId: profileId),
                  repo.watchRealMoneyMovementsForMonth(
                      profileId: profileId,
                      month: _month,
                      includeCardPayments: false),
                ]),
                builder: (context, snap) {
                  if (!snap.hasData) return const SizedBox.shrink();
                  final entries = snap.data![0] as List<BudgetEntry>;
                  final splits =
                      snap.data![1] as Map<int, List<TransactionSplit>>;
                  final movements = snap.data![2] as Map<String, int>;

                  // What you spent, by category, counted when you spent it
                  // (a card purchase included), plus transfers to your other
                  // accounts and loan payments.
                  final spent = <String, int>{};
                  final income = <String, int>{};
                  for (final r
                      in HomebaseRepository.expandForCategoryTotals(
                          entries, splits)) {
                    final map =
                        r.type == EntryType.expense ? spent : income;
                    map[r.category] = (map[r.category] ?? 0) + r.amountCents;
                  }
                  final outflows = {
                    ...spent,
                    for (final e in movements.entries)
                      e.key: (spent[e.key] ?? 0) + e.value,
                  };
                  final unspent = income.values.fold<int>(0, (s, v) => s + v) -
                      outflows.values.fold<int>(0, (s, v) => s + v);
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 320,
                        child: IncomeSankeyChart(
                          incomeByCategory: income,
                          expenseByCategory: outflows,
                        ),
                      ),
                      if (unspent > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 12),
                          child: Text(
                            '${fmtCents(unspent)} of this month\'s income has '
                            'not been spent or moved yet.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  );
                },
              ),
          ),
        ),
        kSectionGap,
        StreamBuilder<
            List<({DateTime month, int incomeCents, int expenseCents})>>(
          stream: repo.watchCashflow(profileId: profileId),
          builder: (context, snap) {
            final data = snap.data ?? [];
            final hasAny =
                data.any((m) => m.incomeCents > 0 || m.expenseCents > 0);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionHeader(
                  'Income vs spending',
                  icon: Icons.bar_chart_outlined,
                  info: InfoButton(
                    title: 'Income vs spending',
                    body: [
                      'Income versus spending for each of the last six '
                          'months, built from your entries. A card purchase '
                          'counts as spending when you make it, so this is '
                          'what you spent, not what left your accounts. The '
                          'chart above follows the money leaving your '
                          'accounts.',
                      'Green bars are income, red bars are expenses. When '
                          'the red bar is taller than the green one, you '
                          'spent more than you earned that month.',
                    ],
                  ),
                ),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: hasAny
                        ? SizedBox(
                            height: 220,
                            child: CashflowChart(
                              data: data,
                              income: scheme.primary,
                              expense: scheme.error,
                              label: scheme.onSurface,
                            ),
                          )
                        : const Padding(
                            padding: EdgeInsets.all(16),
                            child: EmptyState(
                              icon: Icons.bar_chart_outlined,
                              title: 'Nothing to compare yet',
                              message: 'Add income and spending to see them '
                                  'side by side by month.',
                            ),
                          ),
                  ),
                ),
              ],
            );
          },
        ),
        kSectionGap,
        ProjectedCashBalanceSection(profileId: profileId, scheme: scheme),
      ],
    );
  }

  Widget _monthBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.chevron_left),
            onPressed: () => setState(
                () => _month = DateTime(_month.year, _month.month - 1)),
          ),
          Text('${_monthNames[_month.month - 1]} ${_month.year}',
              style: Theme.of(context).textTheme.titleMedium),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            onPressed: () => setState(
                () => _month = DateTime(_month.year, _month.month + 1)),
          ),
          if (!_isCurrentMonth)
            TextButton(
              onPressed: () {
                final now = DateTime.now();
                setState(() => _month = DateTime(now.year, now.month));
              },
              child: const Text('This month'),
            ),
        ],
      ),
    );
  }
}
