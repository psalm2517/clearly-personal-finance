import 'package:flutter/material.dart';

import '../data/categories.dart';

/// A category chooser: one column, alphabetical, each built-in category with
/// a line saying what belongs in it. The person's own categories follow
/// under their own heading. Scrolls inside whatever height it is given.
class CategoryPicker extends StatelessWidget {
  const CategoryPicker({
    super.key,
    required this.used,
    required this.selected,
    required this.onSelected,
    this.exclude,
  });

  /// Every category in use, so the person's own ones are offered too.
  final Iterable<String> used;
  final String? selected;
  final ValueChanged<String> onSelected;

  /// A category not to offer (the one being moved away from).
  final String? exclude;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final groups = orderedCategories(used);
    final builtIn = groups.builtIn.where((c) => c != exclude).toList();
    final yours = groups.yours.where((c) => c != exclude).toList();

    Widget row(String name, {String? hint}) {
      final on = name == selected;
      return InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => onSelected(name),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: on ? scheme.primary.withValues(alpha: 0.14) : null,
          ),
          child: Row(
            children: [
              Icon(
                on ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 18,
                color: on ? scheme.primary : scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: TextStyle(
                        fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                    if (hint != null)
                      Text(
                        hint,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      shrinkWrap: true,
      children: [
        for (final c in builtIn) row(c, hint: categoryHints[c]),
        if (yours.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 14, 12, 6),
            child: Text(
              'YOURS',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.1,
                fontWeight: FontWeight.w700,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          for (final c in yours) row(c),
        ],
      ],
    );
  }
}
