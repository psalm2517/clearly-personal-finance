import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/categories.dart';
import '../data/database.dart';
import '../main.dart';
import '../util/money.dart';
import 'category_picker.dart';
import 'common.dart';

/// One line of a category: either a whole entry or one slice of a split.
class _Line {
  const _Line(this.entry, this.amountCents, {required this.isSlice});
  final BudgetEntry entry;
  final int amountCents;
  final bool isSlice;
}

/// What was spent in a month, grouped by category, largest first. Each
/// category opens to the transactions behind it, and each transaction can be
/// moved to a different category on the spot, so "Other" can be cleaned up
/// from the same place it shows up.
class SpendingByCategory extends ConsumerStatefulWidget {
  const SpendingByCategory({
    super.key,
    required this.entries,
    required this.splits,
    required this.previousTotals,
  });

  final List<BudgetEntry> entries;
  final Map<int, List<TransactionSplit>> splits;

  /// Last month's spending by category, for the change shown on each row.
  final Map<String, int> previousTotals;

  @override
  ConsumerState<SpendingByCategory> createState() => _SpendingByCategoryState();
}

class _SpendingByCategoryState extends ConsumerState<SpendingByCategory> {
  final _open = <String>{};

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

  Map<String, List<_Line>> _group() {
    final by = <String, List<_Line>>{};
    for (final e in widget.entries) {
      if (e.type != EntryType.expense || e.category == Cat.transfers) {
        continue;
      }
      final slices = widget.splits[e.id];
      if (slices == null || slices.isEmpty) {
        by
            .putIfAbsent(e.category, () => [])
            .add(_Line(e, e.amountCents, isSlice: false));
      } else {
        for (final s in slices) {
          by
              .putIfAbsent(s.category, () => [])
              .add(_Line(e, s.amountCents, isSlice: true));
        }
      }
    }
    for (final lines in by.values) {
      lines.sort((a, b) => b.entry.date.compareTo(a.entry.date));
    }
    return by;
  }

  Future<void> _recategorize(_Line line, List<String> known) async {
    final result = await showDialog<({String category, bool similar})>(
      context: context,
      builder: (_) => _CategoryDialog(entry: line.entry, known: known),
    );
    if (result == null || !mounted) return;
    final changed = await ref
        .read(repositoryProvider)
        .setEntryCategory(
          profileId: line.entry.profileId,
          id: line.entry.id,
          category: result.category,
          applyToSimilar: result.similar,
        );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            changed > 1
                ? 'Moved $changed transactions to ${result.category}.'
                : 'Moved to ${result.category}.',
          ),
        ),
      );
  }

  Future<void> _moveAll(String from, List<String> known) async {
    final result = await showDialog<String>(
      context: context,
      builder: (_) => _MoveAllDialog(from: from, known: known),
    );
    if (result == null || !mounted) return;
    final profileId = ref.read(activeProfileProvider)!.id;
    final changed = await ref
        .read(repositoryProvider)
        .renameCategory(profileId: profileId, from: from, to: result);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text('Moved $changed items from $from to $result.')),
      );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = _group();
    final totals = {
      for (final g in groups.entries)
        g.key: g.value.fold(0, (s, l) => s + l.amountCents),
    };
    final total = totals.values.fold(0, (s, v) => s + v);
    if (total == 0) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'No spending this month yet.',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    final order = totals.keys.toList()
      ..sort((a, b) => totals[b]!.compareTo(totals[a]!));
    // The built-in categories are always offered, then anything the person
    // has used that is not one of them.
    final known = <String>[
      ...defaultSpendingCategories,
      ...({...totals.keys, ...widget.previousTotals.keys}
          .where((c) => c != 'Split' && !defaultSpendingCategories.contains(c))
          .toList()
        ..sort()),
    ];
    final biggest = totals[order.first]!;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final cat in order) ...[
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(
              () => _open.contains(cat) ? _open.remove(cat) : _open.add(cat),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Icon(
                        _open.contains(cat)
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 6),
                      CategoryDot(cat),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          cat,
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Move everything in $cat to another category',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          Icons.drive_file_move_outline,
                          size: 18,
                        ),
                        onPressed: () => _moveAll(cat, known),
                      ),
                      Text(
                        _share(totals[cat]!, total),
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 110,
                        child: Text(
                          fmtCents(totals[cat]!),
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      const SizedBox(width: 24),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: totals[cat]! / biggest,
                            minHeight: 8,
                            backgroundColor: scheme.surfaceContainerHighest,
                            color: categoryColor(context, cat),
                          ),
                        ),
                      ),
                      const SizedBox(width: 14),
                      SizedBox(
                        width: 110,
                        child: _Change(
                          now: totals[cat]!,
                          before: widget.previousTotals[cat],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (_open.contains(cat))
            Padding(
              padding: const EdgeInsets.only(left: 28, bottom: 8),
              child: Column(
                children: [
                  for (final line in groups[cat]!)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        line.entry.payee?.isNotEmpty == true
                            ? line.entry.payee!
                            : (line.entry.description?.isNotEmpty == true
                                  ? line.entry.description!
                                  : line.entry.category),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${_months[line.entry.date.month - 1]} '
                        '${line.entry.date.day}'
                        '${line.isSlice ? '  ·  part of a split' : ''}',
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            fmtCents(line.amountCents),
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (!line.isSlice)
                            TextButton(
                              onPressed: () => _recategorize(line, known),
                              child: const Text('Categorize'),
                            )
                          else
                            const SizedBox(width: 90),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

/// A share of the total, never a misleading "0%" for something small.
String _share(int part, int total) {
  if (total <= 0 || part <= 0) return '0%';
  final pct = part / total * 100;
  return pct < 1 ? '<1%' : '${pct.round()}%';
}

/// "Up $120 vs last month" in plain colors: spending going up is the warm
/// color, going down the calm one.
class _Change extends StatelessWidget {
  const _Change({required this.now, required this.before});
  final int now;
  final int? before;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (before == null) {
      return Text(
        'new',
        textAlign: TextAlign.right,
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
      );
    }
    final diff = now - before!;
    if (diff == 0) {
      return Text(
        'same as last month',
        textAlign: TextAlign.right,
        style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
      );
    }
    final up = diff > 0;
    return Text(
      '${up ? '↑' : '↓'} ${fmtCents(diff.abs())}',
      textAlign: TextAlign.right,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: up ? scheme.error : scheme.primary,
      ),
    );
  }
}

class _CategoryDialog extends StatefulWidget {
  const _CategoryDialog({required this.entry, required this.known});
  final BudgetEntry entry;
  final List<String> known;

  @override
  State<_CategoryDialog> createState() => _CategoryDialogState();
}

class _CategoryDialogState extends State<_CategoryDialog> {
  late final _custom = TextEditingController();
  late String? _picked = widget.entry.category;
  var _similar = true;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  String get _chosen =>
      _custom.text.trim().isNotEmpty ? _custom.text.trim() : (_picked ?? '');

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final label = e.payee?.isNotEmpty == true
        ? e.payee!
        : (e.description?.isNotEmpty == true ? e.description! : 'this');
    return AlertDialog(
      title: const Text('Categorize'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$label  ·  ${fmtCents(e.amountCents)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 300,
                child: CategoryPicker(
                  used: widget.known,
                  selected: _custom.text.trim().isEmpty ? _picked : null,
                  onSelected: (c) => setState(() {
                    _custom.clear();
                    _picked = c;
                  }),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _custom,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Or a new category',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _similar,
                onChanged: (v) => setState(() => _similar = v ?? false),
                title: Text('Always use this for "$label"'),
                subtitle: const Text(
                  'Moves the ones already there and sorts new ones '
                  'automatically.',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _chosen.isEmpty
              ? null
              : () => Navigator.pop(context, (
                  category: _chosen,
                  similar: _similar,
                )),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

/// Pick the category everything in [from] should move to.
class _MoveAllDialog extends StatefulWidget {
  const _MoveAllDialog({required this.from, required this.known});
  final String from;
  final List<String> known;

  @override
  State<_MoveAllDialog> createState() => _MoveAllDialogState();
}

class _MoveAllDialogState extends State<_MoveAllDialog> {
  final _custom = TextEditingController();
  String? _picked;

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  String get _chosen =>
      _custom.text.trim().isNotEmpty ? _custom.text.trim() : (_picked ?? '');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Move everything in ${widget.from}'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Every transaction, split, rule and budget target '
                'in this category moves, in every month.',
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 300,
                child: CategoryPicker(
                  used: widget.known,
                  exclude: widget.from,
                  selected: _custom.text.trim().isEmpty ? _picked : null,
                  onSelected: (c) => setState(() {
                    _custom.clear();
                    _picked = c;
                  }),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _custom,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Or a new category',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _chosen.isEmpty
              ? null
              : () => Navigator.pop(context, _chosen),
          child: const Text('Move'),
        ),
      ],
    );
  }
}
