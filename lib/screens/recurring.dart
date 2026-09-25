import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../main.dart';
import '../util/money.dart';
import '../widgets/common.dart';
import 'accounts.dart';

String recurringFreqLabel(PayFrequency f) => switch (f) {
      PayFrequency.weekly => 'Weekly',
      PayFrequency.biweekly => 'Bi-weekly',
      PayFrequency.semimonthly => 'Semi-monthly (1st & 15th style)',
      PayFrequency.monthly => 'Monthly',
    };

/// Recurring income or expense that isn't a bill or a paycheck — a
/// subscription, rental income, a side-gig deposit, anything on its own
/// cadence. Posts a budget entry automatically, and moves an account or
/// card balance too if one is linked.
class RecurringTransactionsScreen extends ConsumerWidget {
  const RecurringTransactionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    final profileId = ref.watch(activeProfileProvider)!.id;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      body: StreamBuilder<List<dynamic>>(
        stream: combineLatest<dynamic>([
          repo.watchRecurringTransactions(profileId: profileId),
          repo.watchAccounts(profileId: profileId),
          repo.watchCards(profileId: profileId),
        ]),
        builder: (context, snap) {
          if (!snap.hasData) return const SizedBox.shrink();
          final items = snap.data![0] as List<RecurringTransaction>;
          final accounts = snap.data![1] as List<Account>;
          final cards = snap.data![2] as List<CreditCard>;

          String? linkLabel(RecurringTransaction r) {
            if (r.accountId != null) {
              return accounts
                      .where((a) => a.id == r.accountId)
                      .firstOrNull
                      ?.name ??
                  'Deleted account';
            }
            if (r.cardId != null) {
              return cards.where((c) => c.id == r.cardId).firstOrNull?.name ??
                  'Deleted card';
            }
            return null;
          }

          if (items.isEmpty) {
            return const EmptyState(
              icon: Icons.autorenew,
              title: 'No recurring transactions',
              message: 'Use Add at the top and turn on Repeats for a '
                  'subscription or anything else that posts on a schedule. '
                  'It shows up here so you can pause or change it.',
            );
          }

          return ListView(
            padding: kPagePadding,
            children: [
              SectionHeader('Recurring',
                  icon: Icons.autorenew,
                  info: const InfoButton(
                    title: 'General recurring transactions',
                    body: [
                      'For income or spending that repeats but isn\'t a bill '
                          'or a paycheck — a streaming subscription, rental '
                          'income, a side-gig deposit.',
                      'Posts itself as a budget entry automatically, on the '
                          'schedule below, the same way autopay bills and '
                          'paychecks handle themselves.',
                      'Linking an account or card also moves its balance; '
                          'leaving it unlinked just tracks the entry.',
                    ],
                  )),
              Card(
                child: Column(
                  children: [
                    for (final r in items)
                      ListTile(
                        leading: Icon(
                          r.active
                              ? (r.type == EntryType.income
                                  ? Icons.arrow_downward
                                  : Icons.arrow_upward)
                              : Icons.pause_circle_outline,
                          color: !r.active
                              ? scheme.onSurfaceVariant
                              : r.type == EntryType.income
                                  ? scheme.primary
                                  : scheme.error,
                        ),
                        title: Text(r.name),
                        subtitle: Text(
                            '${r.category} • ${recurringFreqLabel(r.frequency)}'
                            '${linkLabel(r) != null ? ' • ${linkLabel(r)}' : ''}'
                            '${r.active ? '' : ' • paused'}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '${r.type == EntryType.income ? '+' : '-'}'
                              '${fmtCents(r.amountCents)}',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: r.type == EntryType.income
                                    ? scheme.primary
                                    : null,
                              ),
                            ),
                            IconButton(
                                tooltip: 'Edit',
                                icon:
                                    const Icon(Icons.edit_outlined, size: 18),
                                onPressed: () => _edit(context, ref, r)),
                            IconButton(
                                tooltip: 'Delete',
                                icon: const Icon(Icons.delete_outline,
                                    size: 18),
                                onPressed: () => _delete(context, ref, r)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _delete(
      BuildContext context, WidgetRef ref, RecurringTransaction r) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${r.name}?'),
        content: const Text(
            'Every posted occurrence is removed, and any balance it moved '
            'is put back.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          DangerButton(
              label: 'Delete',
              onPressed: () => Navigator.pop(context, true)),
        ],
      ),
    );
    if (ok == true) {
      await ref.read(repositoryProvider).deleteRecurringTransaction(
          profileId: ref.read(activeProfileProvider)!.id, id: r.id);
    }
  }

  Future<void> _edit(BuildContext context, WidgetRef ref,
      RecurringTransaction? existing) async {
    final repo = ref.read(repositoryProvider);
    final profileId = ref.read(activeProfileProvider)!.id;
    final accounts = await repo.watchAccounts(profileId: profileId).first;
    final cards = await repo.watchCards(profileId: profileId).first;
    if (!context.mounted) return;

    final name = TextEditingController(text: existing?.name);
    final amount = TextEditingController(
        text:
            existing == null ? '' : (existing.amountCents / 100).toString());
    final category = TextEditingController(text: existing?.category ?? 'Other');
    var type = existing?.type ?? EntryType.expense;
    var frequency = existing?.frequency ?? PayFrequency.monthly;
    var anchorDate = existing?.anchorDate ?? DateTime.now();
    var active = existing?.active ?? true;
    // Encoded as "account:3" or "card:2" so one dropdown can offer both.
    String? link = existing == null
        ? null
        : existing.accountId != null
            ? 'account:${existing.accountId}'
            : existing.cardId != null
                ? 'card:${existing.cardId}'
                : null;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => SubmitOnEnter(
          onSubmit: () => Navigator.pop(context, true),
          child: AlertDialog(
            title:
                Text(existing == null ? 'Add recurring' : 'Edit recurring'),
            content: SizedBox(
              width: 400,
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  DialogField(name, 'Name', autofocus: true),
                  const SizedBox(height: 12),
                  SegmentedButton<EntryType>(
                    segments: const [
                      ButtonSegment(
                          value: EntryType.expense, label: Text('Expense')),
                      ButtonSegment(
                          value: EntryType.income, label: Text('Income')),
                    ],
                    selected: {type},
                    onSelectionChanged: (s) =>
                        setLocal(() => type = s.first),
                  ),
                  const SizedBox(height: 12),
                  DialogField(amount, 'Amount (\$)'),
                  const SizedBox(height: 12),
                  DialogField(category, 'Category'),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<PayFrequency>(
                    initialValue: frequency,
                    decoration: const InputDecoration(
                        labelText: 'Frequency', border: OutlineInputBorder()),
                    items: [
                      for (final f in PayFrequency.values)
                        DropdownMenuItem(
                            value: f, child: Text(recurringFreqLabel(f))),
                    ],
                    onChanged: (v) => setLocal(() => frequency = v!),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.calendar_today, size: 16),
                      label: Text(
                          'Starts ${anchorDate.month}/${anchorDate.day}/${anchorDate.year}'),
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: anchorDate,
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2060),
                          helpText: 'First occurrence',
                        );
                        if (picked != null) {
                          setLocal(() => anchorDate = picked);
                        }
                      },
                    ),
                  ),
                  if (accounts.isNotEmpty || cards.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      initialValue: link,
                      decoration: const InputDecoration(
                          labelText: 'Linked to (optional)',
                          helperText: 'Also moves an account\'s balance, or '
                              'a card\'s, each time this posts',
                          helperMaxLines: 2,
                          border: OutlineInputBorder()),
                      items: [
                        const DropdownMenuItem(
                            value: null, child: Text('Not linked')),
                        for (final a in accounts)
                          DropdownMenuItem(
                            value: 'account:${a.id}',
                            child: Row(children: [
                              Icon(accountIcon(a.type),
                                  size: 16,
                                  color: accountTypeColor(context, a.type)),
                              const SizedBox(width: 8),
                              Text(a.name),
                            ]),
                          ),
                        for (final c in cards)
                          DropdownMenuItem(
                            value: 'card:${c.id}',
                            child: Row(children: [
                              const Icon(Icons.credit_card, size: 16),
                              const SizedBox(width: 8),
                              Text(c.name),
                            ]),
                          ),
                      ],
                      onChanged: (v) => setLocal(() => link = v),
                    ),
                  ],
                  SwitchListTile(
                    title: const Text('Active'),
                    contentPadding: EdgeInsets.zero,
                    value: active,
                    onChanged: (v) => setLocal(() => active = v),
                  ),
                ]),
              ),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Save')),
            ],
          ),
        ),
      ),
    );
    if (saved != true) return;
    if (name.text.trim().isEmpty) {
      if (context.mounted) warnNotSaved(context, 'give it a name');
      return;
    }
    final cents = parseDollarsToCents(amount.text);
    if (cents == null || cents <= 0) {
      if (context.mounted) {
        warnNotSaved(context, 'enter an amount greater than zero');
      }
      return;
    }

    final linkParts = link?.split(':');
    final linkedAccountId = linkParts != null && linkParts[0] == 'account'
        ? int.parse(linkParts[1])
        : null;
    final linkedCardId = linkParts != null && linkParts[0] == 'card'
        ? int.parse(linkParts[1])
        : null;

    await repo.upsertRecurringTransaction(RecurringTransactionsCompanion(
      id: existing == null ? const Value.absent() : Value(existing.id),
      profileId: Value(profileId),
      name: Value(name.text.trim()),
      type: Value(type),
      amountCents: Value(cents),
      category: Value(
          category.text.trim().isEmpty ? 'Other' : category.text.trim()),
      frequency: Value(frequency),
      anchorDate: Value(anchorDate),
      accountId: Value(linkedAccountId),
      cardId: Value(linkedCardId),
      active: Value(active),
    ));
  }
}
