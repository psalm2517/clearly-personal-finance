import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../main.dart';
import '../util/money.dart';
import '../widgets/common.dart';

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December'
];

/// A simple month view: what came in, what went out, what is left, and where
/// it went. Forward-looking planning lives on the Dashboard instead, so this
/// screen only ever describes the month you are looking at.
class BudgetScreen extends ConsumerStatefulWidget {
  const BudgetScreen({super.key});

  @override
  ConsumerState<BudgetScreen> createState() => _BudgetScreenState();
}

class _BudgetScreenState extends ConsumerState<BudgetScreen> {
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  bool get _isCurrentMonth {
    final now = DateTime.now();
    return _month.year == now.year && _month.month == now.month;
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final profileId = ref.watch(activeProfileProvider)!.id;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: StreamBuilder<List<dynamic>>(
        stream: combineLatest<dynamic>([
          repo.watchBudgetForMonth(profileId: profileId, month: _month),
          repo.watchBudgetTargets(profileId: profileId),
          repo.watchExpectedIncomeForMonth(
              profileId: profileId, month: _month),
          repo.watchBillsDueByCategoryForMonth(
              profileId: profileId, month: _month),
          repo.watchReserveForIrregularBillsCents(profileId: profileId),
          repo.watchReserveForCardFeesCents(profileId: profileId),
          repo.watchSplitsByEntry(profileId: profileId),
          repo.watchBillsPaidThisMonthCents(
              profileId: profileId, month: _month),
          repo.watchTransferTargetTotalsForMonth(
              profileId: profileId, month: _month),
        ]),
        builder: (context, snap) {
          if (!snap.hasData) return const SizedBox.shrink();
          final entries = snap.data![0] as List<BudgetEntry>;
          final targets = snap.data![1] as List<BudgetTarget>;
          final expectedIncome = snap.data![2] as int;
          final billsDue = snap.data![3] as Map<String, int>;
          final setAside = (snap.data![4] as int) + (snap.data![5] as int);
          final splitsByEntry =
              snap.data![6] as Map<int, List<TransactionSplit>>;
          final billsPaid = snap.data![7] as int;
          final transferTotals = snap.data![8] as Map<String, int>;
          return _body(
              context,
              entries,
              targets,
              expectedIncome,
              billsDue,
              billsPaid,
              transferTotals,
              setAside, splitsByEntry, scheme);
        },
      ),
    );
  }

  Widget _body(
      BuildContext context,
      List<BudgetEntry> entries,
      List<BudgetTarget> targets,
      int expectedIncomeCents,
      Map<String, int> billsDueByCategory,
      int billsPaidCents,
      Map<String, int> transferTotals,
      int setAsideCents,
      Map<int, List<TransactionSplit>> splitsByEntry,
      ColorScheme scheme) {
    final moneyIn = entries
        .where((e) => e.type == EntryType.income)
        .fold(0, (s, e) => s + e.amountCents);
    final moneyOut = entries
        .where((e) => e.type == EntryType.expense)
        .fold(0, (s, e) => s + e.amountCents);

    // Each category is planned once: at its target, or at its bills where
    // there is no target. Bill payments count toward their category's
    // spending, so adding bills on top of a target for the same category
    // would count that money twice.
    final plan = HomebaseRepository.planCommitments(
      targetByCategory: {
        for (final t in targets) t.category: t.monthlyTargetCents
      },
      billsDueByCategory: billsDueByCategory,
    );
    final targetsTotal = plan.targetsCents;
    final billsBeyondTargets = plan.billsBeyondTargetsCents;
    final unallocated =
        expectedIncomeCents - targetsTotal - billsBeyondTargets;

    // A split entry counts under each of its own categories here, not once
    // under its parent's fallback category.
    final categoryRows =
        HomebaseRepository.expandForCategoryTotals(entries, splitsByEntry);
    final spentByCategory = <String, int>{};
    final incomeByCategory = <String, int>{};
    for (final r in categoryRows) {
      final map = r.type == EntryType.expense ? spentByCategory : incomeByCategory;
      map[r.category] = (map[r.category] ?? 0) + r.amountCents;
    }
    // Money transferred toward a category counts against its target too — a
    // transfer to an investment account is exactly what an "Invest" target
    // is for, even though it is never a budget entry.
    int usedIn(String category) =>
        (spentByCategory[category] ?? 0) + (transferTotals[category] ?? 0);
    final categories = {
      ...spentByCategory.keys,
      ...transferTotals.keys,
      ...targets.map((t) => t.category)
    }.toList()
      ..sort((a, b) => usedIn(b).compareTo(usedIn(a)));

    return Column(
      children: [
        _monthBar(context),
        Expanded(
          child: ListView(
            padding: kPagePadding,
            children: [
              Wrap(spacing: 16, runSpacing: 16, children: [
                StatCard(
                  label: 'Income this month',
                  value: fmtCents(expectedIncomeCents),
                  icon: Icons.arrow_downward,
                  color: scheme.primary,
                  note: moneyIn == expectedIncomeCents
                      ? 'all received'
                      : '${fmtCents(moneyIn)} received so far',
                  info: const InfoButton(
                    title: 'Income this month',
                    body: [
                      'What your paychecks for this month add up to, whether '
                          'or not payday has arrived yet — so you can budget '
                          'the whole month from the 1st instead of watching '
                          'the number climb.',
                      'It is the real sum of this month\'s paychecks, not an '
                          'average, so a month with three paydays shows three '
                          'paychecks. Bonuses are included.',
                      'The smaller line underneath tells you how much of it '
                          'has actually landed so far.',
                      'Add or remove paychecks on the Paychecks screen; they '
                          'are generated 90 days ahead from your schedule.',
                    ],
                  ),
                ),
                StatCard(
                  label: 'Spent so far',
                  value: fmtCents(moneyOut),
                  icon: Icons.arrow_upward,
                  color: scheme.error,
                  note: billsPaidCents > 0
                      ? '${fmtCents(billsPaidCents)} of that is bills paid'
                      : null,
                ),
                StatCard(
                  label: 'Free to spend',
                  value: fmtCents(unallocated),
                  icon: Icons.savings_outlined,
                  color:
                      unallocated >= 0 ? scheme.secondary : scheme.error,
                  note: unallocated >= 0
                      ? 'after your plan for the month'
                      : 'over-allocated',
                  info: const InfoButton(
                    title: 'Free to spend',
                    body: [
                      'This month\'s income minus everything already spoken '
                          'for: your category targets, plus any bills that '
                          'are not covered by one.',
                      'A target is a commitment, so it counts as allocated '
                          'even before you spend it — setting a \$400 '
                          'grocery target lowers this by \$400 immediately. '
                          'Bills in that same category are part of it, not '
                          'added on top.',
                      'It is steady from the 1st, because it counts paychecks '
                          'you are due as well as ones already received.',
                      'If it goes red you have allocated more than you earn '
                          'this month — lower a target or trim a bill.',
                      'The breakdown is in the plan below.',
                    ],
                  ),
                ),
              ]),
              kSectionGap,
              SectionHeader('Plan for this month',
                  icon: Icons.calculate_outlined,
                  info: const InfoButton(
                    title: 'Plan for this month',
                    body: [
                      'The arithmetic behind "free to spend": this month\'s '
                          'income, minus your category targets, minus any '
                          'bills that are not covered by a target.',
                      'Every category is counted once. A category is planned '
                          'at its target; if you have not set one, at the '
                          'bills that charge in it this month. A bill that '
                          'has a target on its category is inside that '
                          'target, not on top of it.',
                      '"Set aside" is a recommendation, not a bill. Annual '
                          'and quarterly costs are divided across their term '
                          '— a \$325 card fee is \$27.08 a month — so the '
                          'charge does not blindside you when it lands. That '
                          'money has not left your account, which is why it '
                          'is listed separately rather than subtracted above.',
                      'The last line is what is genuinely yours to spend once '
                          'you have put that reserve away.',
                    ],
                  )),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _planRow(context, 'Income this month',
                          fmtCents(expectedIncomeCents)),
                      if (targetsTotal > 0)
                        _planRow(context, 'Category targets you have set',
                            '-${fmtCents(targetsTotal)}'),
                      if (billsBeyondTargets > 0)
                        _planRow(context, 'Bills not covered by a target',
                            '-${fmtCents(billsBeyondTargets)}'),
                      const Divider(),
                      _planRow(context, 'Left to budget',
                          fmtCents(unallocated),
                          bold: true,
                          color: unallocated >= 0 ? null : scheme.error),
                      if (setAsideCents > 0) ...[
                        const SizedBox(height: 12),
                        Row(children: [
                          Icon(Icons.savings_outlined,
                              size: 14, color: scheme.secondary),
                          const SizedBox(width: 6),
                          Text('Recommended',
                              style: Theme.of(context)
                                  .textTheme
                                  .labelMedium
                                  ?.copyWith(color: scheme.secondary)),
                        ]),
                        const SizedBox(height: 4),
                        _planRow(
                            context,
                            'Put away for annual and quarterly costs',
                            fmtCents(setAsideCents),
                            color: scheme.secondary),
                        _planRow(
                            context,
                            'Left after setting that aside',
                            fmtCents(unallocated - setAsideCents),
                            color: scheme.secondary),
                      ],
                    ],
                  ),
                ),
              ),
              kSectionGap,
              SectionHeader('Where it went',
                  icon: Icons.donut_small_outlined,
                  info: const InfoButton(
                    title: 'Where it went',
                    body: [
                      'This month\'s spending grouped by category, biggest '
                          'first. A transfer counts here too if you gave it a '
                          '"counts toward" category, so money moved to savings '
                          'or investments shows against a target like Invest.',
                      'If you set a target for a category, a bar shows how '
                          'much of it you have used, turning red once you go '
                          'over. Targets are optional — without one you just '
                          'see the amount.',
                      'Set one with the button on any row here, or manage '
                          'them all with Targets at the top.',
                    ],
                  )),
              if (categories.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: EmptyState(
                      icon: Icons.donut_small_outlined,
                      title: 'Nothing spent yet',
                      message:
                          'Expenses appear here as you mark bills paid or add '
                          'entries.',
                    ),
                  ),
                )
              else
                Card(
                  child: Column(
                    children: [
                      for (final cat in categories)
                        _categoryTile(context, cat, usedIn(cat),
                            _targetFor(targets, cat), scheme,
                            transferredCents: transferTotals[cat] ?? 0),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _monthBar(BuildContext context) {
    return Material(
      color: Theme.of(context)
          .colorScheme
          .surfaceContainerHighest
          .withValues(alpha: 0.35),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            IconButton(
              tooltip: 'Previous month',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => setState(
                  () => _month = DateTime(_month.year, _month.month - 1)),
            ),
            Text('${_monthNames[_month.month - 1]} ${_month.year}',
                style: Theme.of(context).textTheme.titleMedium),
            IconButton(
              tooltip: 'Next month',
              icon: const Icon(Icons.chevron_right),
              onPressed: () => setState(
                  () => _month = DateTime(_month.year, _month.month + 1)),
            ),
            if (!_isCurrentMonth)
              TextButton.icon(
                icon: const Icon(Icons.today, size: 16),
                label: const Text('This month'),
                onPressed: () {
                  final now = DateTime.now();
                  setState(() => _month = DateTime(now.year, now.month));
                },
              ),
            const Spacer(),
            TextButton.icon(
              onPressed: () => _manageTargets(context),
              icon: const Icon(Icons.track_changes, size: 18),
              label: const Text('Targets'),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: () => _manageRules(context),
              icon: const Icon(Icons.rule, size: 18),
              label: const Text('Auto-categorize'),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: () => _manageTags(context),
              icon: const Icon(Icons.label_outline, size: 18),
              label: const Text('Tags'),
            ),
          ],
        ),
      ),
    );
  }

  /// A misspelled or abandoned tag has no other way to go away — it can
  /// only ever be created by typing it into an entry, never browsed or
  /// removed from anywhere else.
  Future<void> _manageTags(BuildContext context) async {
    final repo = ref.read(repositoryProvider);
    final profileId = ref.read(activeProfileProvider)!.id;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Tags'),
        content: SizedBox(
          width: 360,
          child: StreamBuilder<List<Tag>>(
            stream: repo.watchTags(profileId: profileId),
            builder: (context, snap) {
              final tags = snap.data ?? [];
              if (tags.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: EmptyState(
                    icon: Icons.label_outline,
                    title: 'No tags yet',
                    message: 'Add one by typing it into an entry\'s Tags '
                        'field when you add it.',
                  ),
                );
              }
              return SizedBox(
                height: 320,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final t in tags)
                      ListTile(
                        leading: CategoryDot(t.name),
                        title: Text(t.name),
                        trailing: IconButton(
                          tooltip: 'Delete tag',
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () async {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text('Delete "${t.name}"?'),
                                content: const Text(
                                    'Removed from every entry it was on. '
                                    'The entries themselves are unaffected.'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(context, false),
                                      child: const Text('Cancel')),
                                  DangerButton(
                                      label: 'Delete',
                                      onPressed: () =>
                                          Navigator.pop(context, true)),
                                ],
                              ),
                            );
                            if (ok == true) {
                              await repo.deleteTag(
                                  profileId: profileId, id: t.id);
                            }
                          },
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close')),
        ],
      ),
    );
  }

  Widget _planRow(BuildContext context, String label, String value,
      {bool bold = false, Color? color}) {
    final style = TextStyle(
        fontWeight: bold ? FontWeight.bold : null, color: color);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Flexible(child: Text(label, style: style)),
          Text(value, style: style),
        ],
      ),
    );
  }

  int? _targetFor(List<BudgetTarget> targets, String category) {
    for (final t in targets) {
      if (t.category == category) return t.monthlyTargetCents;
    }
    return null;
  }

  Widget _categoryTile(BuildContext context, String category, int spentCents,
      int? targetCents, ColorScheme scheme,
      {int transferredCents = 0}) {
    final over = targetCents != null && spentCents > targetCents;
    return ListTile(
      leading: SizedBox(
          width: 24, height: 24, child: Center(child: CategoryDot(category))),
      title: Text(category),
      subtitle: targetCents == null && transferredCents == 0
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (transferredCents > 0)
                  Text('includes ${fmtCents(transferredCents)} transferred',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant)),
                if (targetCents != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: LinearProgressIndicator(
                      value: (spentCents / targetCents).clamp(0.0, 1.0),
                      color: over ? scheme.error : scheme.primary,
                    ),
                  ),
              ],
            ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            targetCents == null
                ? fmtCents(spentCents)
                : '${fmtCents(spentCents)} of ${fmtCents(targetCents)}',
            style: TextStyle(
                fontWeight: FontWeight.w600,
                color: over ? scheme.error : null),
          ),
          const SizedBox(width: 4),
          // The most useful place to set a limit is next to what you spent.
          targetCents == null
              ? TextButton(
                  onPressed: () => _setTarget(context, category, null),
                  child: const Text('Set target'),
                )
              : IconButton(
                  tooltip: 'Change target',
                  icon: const Icon(Icons.track_changes, size: 18),
                  onPressed: () => _setTarget(context, category, targetCents),
                ),
        ],
      ),
    );
  }

  /// Sets or clears the target for one category, without opening the full
  /// targets list.
  Future<void> _setTarget(
      BuildContext context, String category, int? currentCents) async {
    final repo = ref.read(repositoryProvider);
    final profileId = ref.read(activeProfileProvider)!.id;
    final amount = TextEditingController(
        text: currentCents == null ? '' : (currentCents / 100).toString());

    final action = await showDialog<String>(
      context: context,
      builder: (context) => SubmitOnEnter(
        onSubmit: () => Navigator.pop(context, 'save'),
        child: AlertDialog(
          title: Text('Monthly target for $category'),
          content: SizedBox(
            width: 320,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DialogField(amount, 'Target (\$)',
                  autofocus: true,
                  helper: 'What you want to keep this category under'),
            ]),
          ),
          actions: [
            if (currentCents != null)
              TextButton(
                  onPressed: () => Navigator.pop(context, 'clear'),
                  child: const Text('Remove target')),
            TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, 'save'),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (action == null || action == 'cancel') return;

    if (action == 'clear') {
      final targets = await repo.watchBudgetTargets(profileId: profileId).first;
      final existing =
          targets.where((t) => t.category == category).firstOrNull;
      if (existing != null) {
        await repo.deleteBudgetTarget(profileId: profileId, id: existing.id);
      }
      return;
    }

    final cents = parseDollarsToCents(amount.text);
    if (cents == null) return;
    await repo.upsertBudgetTarget(BudgetTargetsCompanion.insert(
        profileId: profileId,
        category: category,
        monthlyTargetCents: cents));
  }

  Future<void> _manageTargets(BuildContext context) async {
    final repo = ref.read(repositoryProvider);
    final profileId = ref.read(activeProfileProvider)!.id;
    final category = TextEditingController();
    final target = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Budget targets'),
        content: SizedBox(
          width: 420,
          height: 400,
          child: Column(children: [
            StatefulBuilder(builder: (context, _) {
              Future<void> add() async {
                final cents = parseDollarsToCents(target.text);
                if (category.text.trim().isEmpty || cents == null) return;
                await repo.upsertBudgetTarget(BudgetTargetsCompanion.insert(
                    profileId: profileId,
                    category: category.text.trim(),
                    monthlyTargetCents: cents));
                category.clear();
                target.clear();
              }

              return Row(children: [
                Expanded(
                    child: TextField(
                        controller: category,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => add(),
                        decoration:
                            const InputDecoration(labelText: 'Category'))),
                const SizedBox(width: 8),
                SizedBox(
                    width: 110,
                    child: TextField(
                        controller: target,
                        onSubmitted: (_) => add(),
                        decoration: const InputDecoration(
                            labelText: 'Target \$'))),
                IconButton(
                    tooltip: 'Add target',
                    icon: const Icon(Icons.add),
                    onPressed: add),
              ]);
            }),
            const SizedBox(height: 8),
            Expanded(
              child: StreamBuilder<List<BudgetTarget>>(
                stream: repo.watchBudgetTargets(profileId: profileId),
                builder: (context, snap) {
                  final targets = snap.data ?? [];
                  return ListView(children: [
                    for (final t in targets)
                      ListTile(
                        title: Text(t.category),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          Text(fmtCents(t.monthlyTargetCents)),
                          IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 18),
                              onPressed: () => repo.deleteBudgetTarget(
                                  profileId: profileId, id: t.id)),
                        ]),
                      ),
                  ]);
                },
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done')),
        ],
      ),
    );
  }

  Future<void> _manageRules(BuildContext context) async {
    final repo = ref.read(repositoryProvider);
    final profileId = ref.read(activeProfileProvider)!.id;
    final pattern = TextEditingController();
    final category = TextEditingController();
    var field = RuleField.description;
    await showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) {
          Future<void> addRule() async {
            if (pattern.text.trim().isEmpty || category.text.trim().isEmpty) {
              return;
            }
            await repo.upsertRule(CategoryRulesCompanion.insert(
                profileId: profileId,
                field: field,
                pattern: pattern.text.trim(),
                category: category.text.trim()));
            pattern.clear();
            category.clear();
          }

          return AlertDialog(
          title: const Text('Auto-categorization rules'),
          content: SizedBox(
            width: 480,
            height: 420,
            child: Column(children: [
              Row(children: [
                DropdownButton<RuleField>(
                  value: field,
                  items: const [
                    DropdownMenuItem(
                        value: RuleField.description,
                        child: Text('Description contains')),
                    DropdownMenuItem(
                        value: RuleField.amount,
                        child: Text('Amount equals')),
                  ],
                  onChanged: (v) => setState(() => field = v!),
                ),
                const SizedBox(width: 8),
                Expanded(
                    child: TextField(
                        controller: pattern,
                        textInputAction: TextInputAction.next,
                        onSubmitted: (_) => addRule(),
                        decoration:
                            const InputDecoration(labelText: 'Pattern'))),
                const SizedBox(width: 8),
                SizedBox(
                    width: 110,
                    child: TextField(
                        controller: category,
                        onSubmitted: (_) => addRule(),
                        decoration:
                            const InputDecoration(labelText: 'Category'))),
                IconButton(
                  tooltip: 'Add rule',
                  icon: const Icon(Icons.add),
                  onPressed: addRule,
                ),
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: StreamBuilder<List<CategoryRule>>(
                  stream: repo.watchRules(profileId: profileId),
                  builder: (context, snap) {
                    final rules = snap.data ?? [];
                    return ListView(children: [
                      for (final r in rules)
                        ListTile(
                          title: Text(
                              '${r.field == RuleField.description ? 'description contains' : 'amount ='} "${r.pattern}"'),
                          subtitle: Text('→ ${r.category}'),
                          trailing: IconButton(
                              icon: const Icon(Icons.delete_outline,
                                  size: 18),
                              onPressed: () => repo.deleteRule(
                                  profileId: profileId, id: r.id)),
                        ),
                    ]);
                  },
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done')),
          ],
        );
        },
      ),
    );
  }
}
