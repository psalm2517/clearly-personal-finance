import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../main.dart';
import '../util/money.dart';
import '../widgets/common.dart';
import '../widgets/net_worth_chart.dart';
import 'accounts.dart' show accountBadge, accountLabel;

/// Where the Accounts hub opens: net worth with its trend, every account,
/// card and loan grouped and collapsible, and a summary of what the number
/// is made of. Rows are read-only here; tapping one opens the matching tab
/// where it can be edited, so nothing was moved out of those screens.
class AccountsOverview extends ConsumerStatefulWidget {
  const AccountsOverview({super.key, required this.onOpenTab});

  /// Switches the hub to a tab: 1 Cash, 2 Cards, 3 Loans.
  final ValueChanged<int> onOpenTab;

  @override
  ConsumerState<AccountsOverview> createState() => _AccountsOverviewState();
}

class _AccountsOverviewState extends ConsumerState<AccountsOverview> {
  static const _ranges = {30: '1 month', 90: '3 months', 180: '6 months'};
  int _days = 180;
  bool _percent = false;

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final profileId = ref.watch(activeProfileProvider)!.id;
    final scheme = Theme.of(context).colorScheme;

    return StreamBuilder<List<NetWorthSnapshot>>(
      stream: repo.watchNetWorthHistory(profileId: profileId, days: _days),
      builder: (context, histSnap) {
        final history = histSnap.data ?? const <NetWorthSnapshot>[];
        return StreamBuilder<List<Object>>(
          stream: combineLatest<Object>([
            repo.watchAccounts(profileId: profileId),
            repo.watchCards(profileId: profileId),
            repo.watchLoans(profileId: profileId),
          ]),
          builder: (context, snap) {
            final data = snap.data;
            final accounts = data == null
                ? const <Account>[]
                : data[0] as List<Account>;
            final cards = data == null
                ? const <CreditCard>[]
                : data[1] as List<CreditCard>;
            final loans =
                data == null ? const <Loan>[] : data[2] as List<Loan>;

            final groups = _groups(context, accounts, cards, loans);
            final assets = groups
                .where((g) => !g.isDebt)
                .fold(0, (s, g) => s + g.totalCents);
            final debts = groups
                .where((g) => g.isDebt)
                .fold(0, (s, g) => s + g.totalCents);

            final main = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _NetWorthHeader(
                  netCents: assets - debts,
                  history: history,
                  days: _days,
                  ranges: _ranges,
                  onRange: (d) => setState(() => _days = d),
                ),
                const SizedBox(height: 12),
                if (history.length >= 2)
                  NetWorthChart(history: history, height: 160)
                else
                  Text(
                    'A line appears once Clearly has recorded two '
                    'separate days.',
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                const SizedBox(height: 24),
                if (groups.isEmpty)
                  const EmptyState(
                    icon: Icons.account_balance_outlined,
                    title: 'No accounts yet',
                    message:
                        'Add an account, card or loan with the Add button '
                        'and it shows up here.',
                  )
                else
                  for (final g in groups)
                    _GroupSection(
                      group: g,
                      onOpen: () => widget.onOpenTab(g.tab),
                    ),
              ],
            );

            final summary = _SummaryPanel(
              groups: groups,
              assets: assets,
              debts: debts,
              percent: _percent,
              onToggle: (p) => setState(() => _percent = p),
            );

            return LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 920;
                return SingleChildScrollView(
                  padding: kPagePadding.copyWith(top: 12),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: main),
                            const SizedBox(width: 28),
                            SizedBox(width: 320, child: summary),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [main, const SizedBox(height: 24), summary],
                        ),
                );
              },
            );
          },
        );
      },
    );
  }

  /// Assets first, then debts, skipping any group with nothing in it.
  List<_Group> _groups(
    BuildContext context,
    List<Account> accounts,
    List<CreditCard> cards,
    List<Loan> loans,
  ) {
    const cashTypes = {
      AccountType.checking,
      AccountType.savings,
      AccountType.cash,
    };
    const investTypes = {AccountType.investment, AccountType.retirement};

    _Row accountRow(Account a) => _Row(
      name: a.name,
      subtitle: [
        if (a.institution != null && a.institution!.isNotEmpty) a.institution!,
        accountLabel(a.type),
      ].join(' · '),
      cents: a.balanceCents,
      leading: accountBadge(context, a.type, size: 32),
    );

    _Group assetGroup(
      String title,
      Color color,
      Iterable<Account> list,
    ) => _Group(
      title: title,
      color: color,
      tab: 1,
      isDebt: false,
      rows: [for (final a in list) accountRow(a)],
    );

    final scheme = Theme.of(context).colorScheme;
    final cash = accounts.where((a) => cashTypes.contains(a.type));
    final invest = accounts.where((a) => investTypes.contains(a.type));
    final other = accounts.where(
      (a) => !cashTypes.contains(a.type) && !investTypes.contains(a.type),
    );

    return [
      assetGroup('Cash', scheme.primary, cash),
      assetGroup('Investments', scheme.tertiary, invest),
      assetGroup('Other assets', scheme.secondary, other),
      _Group(
        title: 'Credit cards',
        color: scheme.error,
        tab: 2,
        isDebt: true,
        rows: [
          for (final c in cards)
            _Row(
              name: c.name,
              subtitle: 'Credit card',
              cents: c.balanceCents,
              leading: const Icon(Icons.credit_card_outlined, size: 20),
            ),
        ],
      ),
      _Group(
        title: 'Loans',
        color: scheme.errorContainer,
        tab: 3,
        isDebt: true,
        rows: [
          for (final l in loans)
            _Row(
              name: l.name,
              subtitle: 'Loan',
              cents: l.balanceCents,
              leading: const Icon(Icons.request_quote_outlined, size: 20),
            ),
        ],
      ),
    ].where((g) => g.rows.isNotEmpty).toList();
  }
}

class _Row {
  const _Row({
    required this.name,
    required this.subtitle,
    required this.cents,
    required this.leading,
  });

  final String name;
  final String subtitle;
  final int cents;
  final Widget leading;
}

class _Group {
  const _Group({
    required this.title,
    required this.color,
    required this.tab,
    required this.isDebt,
    required this.rows,
  });

  final String title;
  final Color color;
  final int tab;
  final bool isDebt;
  final List<_Row> rows;

  int get totalCents => rows.fold(0, (s, r) => s + r.cents);
}

class _NetWorthHeader extends StatelessWidget {
  const _NetWorthHeader({
    required this.netCents,
    required this.history,
    required this.days,
    required this.ranges,
    required this.onRange,
  });

  final int netCents;
  final List<NetWorthSnapshot> history;
  final int days;
  final Map<int, String> ranges;
  final ValueChanged<int> onRange;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final first = history.isEmpty ? null : history.first;
    final change = first == null ? null : netCents - first.netWorthCents;
    final percent = (first == null || first.netWorthCents == 0)
        ? null
        : change! / first.netWorthCents.abs() * 100;
    final up = (change ?? 0) >= 0;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'NET WORTH',
                style: TextStyle(
                  color: scheme.onSurfaceVariant,
                  fontSize: 12,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              MoneyText(
                fmtCents(netCents),
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFamily: 'monospace',
                ),
              ),
              if (change != null && history.length >= 2) ...[
                const SizedBox(height: 4),
                Text(
                  '${up ? '↑' : '↓'} ${fmtCents(change.abs())}'
                  '${percent == null ? '' : ' (${percent.abs().toStringAsFixed(1)}%)'}'
                  ' over ${ranges[days]}',
                  style: TextStyle(
                    color: up ? scheme.primary : scheme.error,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ],
          ),
        ),
        DropdownButton<int>(
          value: days,
          underline: const SizedBox.shrink(),
          onChanged: (d) {
            if (d != null) onRange(d);
          },
          items: [
            for (final e in ranges.entries)
              DropdownMenuItem(value: e.key, child: Text(e.value)),
          ],
        ),
      ],
    );
  }
}

/// One collapsible group: a header with the group's total, and its rows.
class _GroupSection extends StatelessWidget {
  const _GroupSection({required this.group, required this.onOpen});

  final _Group group;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: true,
            shape: const Border(),
            collapsedShape: const Border(),
            tilePadding: const EdgeInsets.symmetric(horizontal: 16),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    group.title,
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                ),
                MoneyText(
                  fmtCents(group.totalCents),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontFamily: 'monospace',
                    fontSize: 16,
                  ),
                ),
              ],
            ),
            children: [
              for (final r in group.rows)
                InkWell(
                  onTap: onOpen,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Row(
                      children: [
                        r.leading,
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                r.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                r.subtitle,
                                style: TextStyle(
                                  color: scheme.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        MoneyText(
                          fmtCents(r.cents),
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }
}

/// Assets and liabilities as a segmented bar with a legend, with a
/// Totals / Percent switch on the figures.
class _SummaryPanel extends StatelessWidget {
  const _SummaryPanel({
    required this.groups,
    required this.assets,
    required this.debts,
    required this.percent,
    required this.onToggle,
  });

  final List<_Group> groups;
  final int assets;
  final int debts;
  final bool percent;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Summary',
                  style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                ),
              ),
              SegmentedButton<bool>(
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                ),
                segments: const [
                  ButtonSegment(value: false, label: Text('Totals')),
                  ButtonSegment(value: true, label: Text('Percent')),
                ],
                selected: {percent},
                onSelectionChanged: (s) => onToggle(s.first),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _SummarySection(
            title: 'Assets',
            total: assets,
            groups: groups.where((g) => !g.isDebt).toList(),
            percent: percent,
          ),
          const SizedBox(height: 22),
          _SummarySection(
            title: 'Liabilities',
            total: debts,
            groups: groups.where((g) => g.isDebt).toList(),
            percent: percent,
          ),
        ],
      ),
    );
  }
}

class _SummarySection extends StatelessWidget {
  const _SummarySection({
    required this.title,
    required this.total,
    required this.groups,
    required this.percent,
  });

  final String title;
  final int total;
  final List<_Group> groups;
  final bool percent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            MoneyText(
              fmtCents(total),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 10,
            child: total <= 0
                ? ColoredBox(color: scheme.surfaceContainerHighest)
                : Row(
                    // Stretch, or the child-less colored boxes collapse to
                    // zero height and the bar disappears.
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final g in groups)
                        if (g.totalCents > 0)
                          Expanded(
                            flex: g.totalCents,
                            child: ColoredBox(color: g.color),
                          ),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 10),
        if (groups.isEmpty)
          Text(
            'None',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        for (final g in groups)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: g.color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(child: Text(g.title)),
                Text(
                  percent
                      ? '${total <= 0 ? 0 : (g.totalCents / total * 100).round()}%'
                      : fmtCents(g.totalCents),
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
