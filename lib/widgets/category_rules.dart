import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/categories.dart';
import '../data/database.dart';
import '../data/merchants.dart';
import '../main.dart';

/// Where the person's own category rules are made and kept: "anything with
/// FANDUEL in it is Entertainment". A rule applies at once to everything
/// already recorded and to every transaction that arrives afterwards.
///
/// Nothing is categorized by a built-in list. [suggestedRules] is only
/// offered as a starting point to pick from.
Future<void> showCategoryRules(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _RulesDialog());

class _RulesDialog extends ConsumerStatefulWidget {
  const _RulesDialog();

  @override
  ConsumerState<_RulesDialog> createState() => _RulesDialogState();
}

class _RulesDialogState extends ConsumerState<_RulesDialog> {
  final _pattern = TextEditingController();
  final _category = TextEditingController();
  String? _note;

  @override
  void dispose() {
    _pattern.dispose();
    _category.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final repo = ref.read(repositoryProvider);
    final profileId = ref.read(activeProfileProvider)!.id;
    final pattern = _pattern.text.trim();
    final category = _category.text.trim();
    if (pattern.isEmpty || category.isEmpty) {
      setState(() => _note = 'Enter the text to look for and a category.');
      return;
    }
    final moved = await repo.addCategoryRule(
      profileId: profileId,
      pattern: pattern,
      category: category,
    );
    if (!mounted) return;
    setState(() {
      _note = moved == 0
          ? 'Rule added. Nothing already recorded matched it.'
          : 'Rule added. Moved $moved transactions to $category.';
      _pattern.clear();
    });
  }

  Future<void> _suggest(List<CategoryRule> have) async {
    final haveText = {for (final r in have) r.pattern.toLowerCase()};
    final picked = await showDialog<List<SuggestedRule>>(
      context: context,
      builder: (_) => _SuggestionsDialog(
        options: [
          for (final r in suggestedRules)
            if (!haveText.contains(r.keyword)) r,
        ],
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final repo = ref.read(repositoryProvider);
    final profileId = ref.read(activeProfileProvider)!.id;
    var moved = 0;
    for (final r in picked) {
      moved += await repo.addCategoryRule(
        profileId: profileId,
        pattern: r.keyword,
        category: r.category,
      );
    }
    if (!mounted) return;
    setState(
      () => _note = 'Added ${picked.length} rules. Moved $moved transactions.',
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final profileId = ref.watch(activeProfileProvider)!.id;
    final scheme = Theme.of(context).colorScheme;

    return StreamBuilder<List<CategoryRule>>(
      stream: repo.watchRules(profileId: profileId),
      builder: (context, snap) {
        final rules =
            (snap.data ?? [])
                .where((r) => r.field == RuleField.description)
                .toList()
              ..sort(
                (a, b) =>
                    a.pattern.toLowerCase().compareTo(b.pattern.toLowerCase()),
              );
        final ordered = orderedCategories([for (final r in rules) r.category]);
        final known = [...ordered.builtIn, ...ordered.yours];

        return AlertDialog(
          title: const Text('Category rules'),
          content: SizedBox(
            width: 560,
            height: 480,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'When a transaction\'s description or payee contains the '
                  'text, it goes to that category. Rules apply now to what is '
                  'already recorded, and to everything that arrives later.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: TextField(
                        controller: _pattern,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'Contains',
                          hintText: 'FANDUEL',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      flex: 5,
                      child: DropdownMenu<String>(
                        controller: _category,
                        expandedInsets: EdgeInsets.zero,
                        enableFilter: true,
                        requestFocusOnTap: true,
                        label: const Text('Category'),
                        dropdownMenuEntries: [
                          for (final c in known)
                            DropdownMenuEntry(value: c, label: c),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: FilledButton(
                        onPressed: _add,
                        child: const Text('Add'),
                      ),
                    ),
                  ],
                ),
                if (_note != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Text(
                      _note!,
                      style: TextStyle(color: scheme.primary),
                    ),
                  ),
                const Divider(height: 28),
                Row(
                  children: [
                    Text(
                      '${rules.length} rules',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: () => _suggest(rules),
                      icon: const Icon(Icons.lightbulb_outline, size: 18),
                      label: const Text('Suggestions'),
                    ),
                  ],
                ),
                Expanded(
                  child: rules.isEmpty
                      ? Center(
                          child: Text(
                            'No rules yet. Add one above, or pick from the '
                            'suggestions.',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      : ListView(
                          children: [
                            for (final r in rules)
                              ListTile(
                                dense: true,
                                title: Text('contains "${r.pattern}"'),
                                subtitle: Text(r.category),
                                trailing: IconButton(
                                  tooltip: 'Delete rule',
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 20,
                                  ),
                                  onPressed: () => repo.deleteRule(
                                    profileId: profileId,
                                    id: r.id,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        );
      },
    );
  }
}

class _SuggestionsDialog extends StatefulWidget {
  const _SuggestionsDialog({required this.options});
  final List<SuggestedRule> options;

  @override
  State<_SuggestionsDialog> createState() => _SuggestionsDialogState();
}

class _SuggestionsDialogState extends State<_SuggestionsDialog> {
  final _picked = <SuggestedRule>{};

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Suggested rules'),
      content: SizedBox(
        width: 520,
        height: 440,
        child: widget.options.isEmpty
            ? const Center(child: Text('You already have all of them.'))
            : ListView(
                children: [
                  for (final r in widget.options)
                    CheckboxListTile(
                      dense: true,
                      value: _picked.contains(r),
                      onChanged: (v) => setState(() {
                        v == true ? _picked.add(r) : _picked.remove(r);
                      }),
                      title: Text('"${r.keyword}"'),
                      subtitle: Text(r.category),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _picked.isEmpty
              ? null
              : () => Navigator.pop(context, _picked.toList()),
          child: Text('Add ${_picked.length}'),
        ),
      ],
    );
  }
}
