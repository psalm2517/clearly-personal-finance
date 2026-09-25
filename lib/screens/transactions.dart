import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/csv_import.dart';
import '../data/database.dart';
import '../data/repository.dart'
    show HomebaseRepository, Movement, MovementKind;
import '../main.dart';
import '../util/money.dart';
import '../widgets/add_transaction.dart';
import '../widgets/common.dart';
import 'import_csv.dart';

/// A full, searchable ledger across every month — the Budget screen only
/// ever shows one month at a time, so finding an older transaction meant
/// paging back one month at a stretch. This is the "find something" view;
/// Budget stays the "plan this month" view.
class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});

  @override
  ConsumerState<TransactionsScreen> createState() =>
      _TransactionsScreenState();
}

/// What the register is filtered to. Transfers and card/loan payments are
/// real money movements but not budget entries, so they get their own kinds.
enum _Kind { all, income, expense, transfer, payment }

/// One line of the register: a budget entry, or a transfer/payment.
typedef _Line = ({DateTime date, BudgetEntry? entry, Movement? movement});

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  String _search = '';
  var _kind = _Kind.all;
  String? _sourceFilter; // "account:3" or "card:2"
  DateTime? _monthFilter; // first day of the month, or any month
  String? _tagFilter;

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final profileId = ref.watch(activeProfileProvider)!.id;
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FloatingActionButton.extended(
              heroTag: 'exportCsv',
              onPressed: () => _exportCsv(context, profileId),
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('Export'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FloatingActionButton.extended(
              heroTag: 'importHistory',
              onPressed: () => _showImportHistory(context, profileId),
              icon: const Icon(Icons.history),
              label: const Text('Imports'),
            ),
          ),
          FloatingActionButton.extended(
            heroTag: 'importCsv',
            onPressed: () => _importCsv(context),
            icon: const Icon(Icons.file_upload_outlined),
            label: const Text('Import CSV'),
          ),
        ],
      ),
      body: StreamBuilder<List<dynamic>>(
        stream: combineLatest<dynamic>([
          repo.watchAllEntries(profileId: profileId),
          repo.watchAccounts(profileId: profileId),
          repo.watchCards(profileId: profileId),
          repo.watchEntryTagNames(profileId: profileId),
          repo.watchSplitsByEntry(profileId: profileId),
          repo.watchMovements(profileId: profileId),
        ]),
        builder: (context, snap) {
          if (!snap.hasData) return const SizedBox.shrink();
          final entries = snap.data![0] as List<BudgetEntry>;
          final accounts = snap.data![1] as List<Account>;
          final cards = snap.data![2] as List<CreditCard>;
          final tagsByEntry = snap.data![3] as Map<int, List<String>>;
          final splitsByEntry =
              snap.data![4] as Map<int, List<TransactionSplit>>;
          final movements = snap.data![5] as List<Movement>;

          final search = _search.trim().toLowerCase();
          bool matchesSource(int? accountId, int? cardId,
              {int? otherAccountId}) {
            if (_sourceFilter == null) return true;
            final parts = _sourceFilter!.split(':');
            final id = int.parse(parts[1]);
            return parts[0] == 'account'
                ? accountId == id || otherAccountId == id
                : cardId == id;
          }

          bool inMonth(DateTime d) =>
              _monthFilter == null ||
              (d.year == _monthFilter!.year && d.month == _monthFilter!.month);

          final lines = <_Line>[
            for (final e in entries)
              if (inMonth(e.date) &&
                  (_tagFilter == null ||
                      (tagsByEntry[e.id] ?? const []).contains(_tagFilter)) &&
                  (_kind == _Kind.all ||
                      (_kind == _Kind.income && e.type == EntryType.income) ||
                      (_kind == _Kind.expense &&
                          e.type == EntryType.expense)) &&
                  matchesSource(e.accountId, e.cardId) &&
                  (search.isEmpty ||
                      e.category.toLowerCase().contains(search) ||
                      (e.description?.toLowerCase().contains(search) ??
                          false) ||
                      (e.payee?.toLowerCase().contains(search) ?? false)))
                (date: e.date, entry: e, movement: null),
            for (final m in movements)
              if (inMonth(m.date) &&
                  _tagFilter == null &&
                  (_kind == _Kind.all ||
                      (_kind == _Kind.transfer &&
                          m.kind == MovementKind.transfer) ||
                      (_kind == _Kind.payment &&
                          m.kind != MovementKind.transfer)) &&
                  matchesSource(m.fromAccountId, m.cardId,
                      otherAccountId: m.toAccountId) &&
                  (search.isEmpty || m.label.toLowerCase().contains(search)))
                (date: m.date, entry: null, movement: m),
          ]..sort((a, b) => b.date.compareTo(a.date));

          final months = {
            for (final e in entries) DateTime(e.date.year, e.date.month),
            for (final m in movements) DateTime(m.date.year, m.date.month),
          }.toList()
            ..sort((a, b) => b.compareTo(a));
          final allTags = {for (final t in tagsByEntry.values) ...t}.toList()
            ..sort();
          const monthNames = [
            'January', 'February', 'March', 'April', 'May', 'June', 'July',
            'August', 'September', 'October', 'November', 'December'
          ];

          String? sourceLabel(BudgetEntry e) {
            if (e.accountId != null) {
              return accounts.where((a) => a.id == e.accountId).firstOrNull?.name;
            }
            if (e.cardId != null) {
              return cards.where((c) => c.id == e.cardId).firstOrNull?.name;
            }
            return null;
          }

          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 20, 28, 0),
                child: TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search description, payee or category',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  onChanged: (v) => setState(() => _search = v),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 12, 28, 0),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      SegmentedButton<_Kind>(
                        segments: const [
                          ButtonSegment(value: _Kind.all, label: Text('All')),
                          ButtonSegment(
                              value: _Kind.income, label: Text('Income')),
                          ButtonSegment(
                              value: _Kind.expense, label: Text('Expense')),
                          ButtonSegment(
                              value: _Kind.transfer,
                              label: Text('Transfers')),
                          ButtonSegment(
                              value: _Kind.payment, label: Text('Payments')),
                        ],
                        selected: {_kind},
                        onSelectionChanged: (s) =>
                            setState(() => _kind = s.first),
                      ),
                      const SizedBox(width: 16),
                      DropdownButton<DateTime?>(
                        value: _monthFilter,
                        hint: const Text('Any month'),
                        items: [
                          const DropdownMenuItem(
                              value: null, child: Text('Any month')),
                          for (final m in months)
                            DropdownMenuItem(
                                value: m,
                                child: Text(
                                    '${monthNames[m.month - 1]} ${m.year}')),
                        ],
                        onChanged: (v) => setState(() => _monthFilter = v),
                      ),
                      if (allTags.isNotEmpty) ...[
                        const SizedBox(width: 16),
                        DropdownButton<String?>(
                          value: _tagFilter,
                          hint: const Text('Any tag'),
                          items: [
                            const DropdownMenuItem(
                                value: null, child: Text('Any tag')),
                            for (final t in allTags)
                              DropdownMenuItem(value: t, child: Text(t)),
                          ],
                          onChanged: (v) => setState(() => _tagFilter = v),
                        ),
                      ],
                      if (accounts.isNotEmpty || cards.isNotEmpty) ...[
                        const SizedBox(width: 16),
                        DropdownButton<String?>(
                          value: _sourceFilter,
                          hint: const Text('Any account'),
                          items: [
                            const DropdownMenuItem(
                                value: null, child: Text('Any account')),
                            for (final a in accounts)
                              DropdownMenuItem(
                                  value: 'account:${a.id}',
                                  child: Text(a.name)),
                            for (final c in cards)
                              DropdownMenuItem(
                                  value: 'card:${c.id}', child: Text(c.name)),
                          ],
                          onChanged: (v) => setState(() => _sourceFilter = v),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              Expanded(
                child: lines.isEmpty
                    ? const EmptyState(
                        icon: Icons.receipt_long_outlined,
                        title: 'No transactions found',
                        message:
                            'Try a different search or clear the filters.',
                      )
                    : ListView(
                        padding: kPagePadding,
                        children: [
                          Card(
                            child: Column(
                              children: [
                                for (final line in lines)
                                  if (line.entry != null)
                                    _row(
                                      context,
                                      line.entry!,
                                      tagsByEntry[line.entry!.id] ?? [],
                                      splitsByEntry[line.entry!.id] ?? [],
                                      sourceLabel(line.entry!),
                                      scheme,
                                    )
                                  else
                                    _movementRow(context, line.movement!,
                                        accounts, scheme),
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

  Widget _row(
    BuildContext context,
    BudgetEntry e,
    List<String> tags,
    List<TransactionSplit> splits,
    String? sourceLabel,
    ColorScheme scheme,
  ) {
    final automatic = HomebaseRepository.isAutomaticEntry(e);
    return ListTile(
      leading: Icon(
        e.type == EntryType.income ? Icons.arrow_downward : Icons.arrow_upward,
        color: e.type == EntryType.income ? scheme.primary : scheme.error,
      ),
      title: Text(e.description ?? e.category),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${splits.isEmpty ? e.category : 'Split'}'
              '${e.payee != null ? ' • ${e.payee}' : ''}'
              '${sourceLabel != null ? ' • $sourceLabel' : ''} • '
              '${_fmtDate(e.date)}'),
          if (tags.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 6,
                children: [
                  for (final tag in tags)
                    Pill(tag, color: categoryColor(context, tag), fontSize: 11),
                ],
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          MoneyText(
            '${e.type == EntryType.income ? '+' : '-'}${fmtCents(e.amountCents)}',
            style: TextStyle(
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
              color: e.type == EntryType.income ? scheme.primary : null,
            ),
          ),
          IconButton(
            tooltip: automatic
                ? 'Added automatically — edit it where it comes from'
                : 'Edit',
            icon: const Icon(Icons.edit_outlined, size: 18),
            onPressed:
                automatic ? null : () => showAddTransaction(context, ref, existing: e),
          ),
          IconButton(
            tooltip: automatic
                ? 'Added automatically — remove it where it comes from'
                : 'Delete',
            icon: const Icon(Icons.delete_outline, size: 18),
            onPressed: automatic ? null : () => _deleteEntry(context, e),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteEntry(BuildContext context, BudgetEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete this transaction?'),
        content: Text(
            '${e.description ?? e.category} (${fmtCents(e.amountCents)}) '
            'is removed, and any balance it moved is put back.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(repositoryProvider).deleteBudgetEntry(
        profileId: ref.read(activeProfileProvider)!.id, id: e.id);
  }

  /// A transfer or card/loan payment. Shown in a neutral colour with no
  /// sign — it moved money but is neither income nor spending.
  Widget _movementRow(BuildContext context, Movement m, List<Account> accounts,
      ColorScheme scheme) {
    String accountName(int? id) =>
        accounts.where((a) => a.id == id).firstOrNull?.name ?? 'Deleted account';
    final detail = m.kind == MovementKind.transfer
        ? '${accountName(m.fromAccountId)} → ${accountName(m.toAccountId)}'
        : m.fromAccountId == null
            ? 'not tracked to an account'
            : 'from ${accountName(m.fromAccountId)}';
    return ListTile(
      leading: Icon(
        m.kind == MovementKind.transfer
            ? Icons.swap_horiz
            : Icons.payments_outlined,
        color: scheme.onSurfaceVariant,
      ),
      title: Text(m.label),
      subtitle: Text('${m.kind == MovementKind.transfer ? 'Transfer' : 'Payment'}'
          ' • $detail • ${_fmtDate(m.date)}'),
      trailing: MoneyText(
        fmtCents(m.amountCents),
        style: const TextStyle(
            fontFamily: 'monospace', fontWeight: FontWeight.w600),
      ),
    );
  }

  static String _fmtDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${months[d.month - 1]} ${ordinalDay(d.day)}, ${d.year}';
  }

  Future<void> _importCsv(BuildContext context) async {
    final file = await openFile(acceptedTypeGroups: const [
      XTypeGroup(label: 'CSV', extensions: ['csv']),
    ]);
    if (file == null) return;

    late final String text;
    late final ({List<String> headers, List<List<dynamic>> rows}) table;
    try {
      text = await file.readAsString();
      table = readCsvTable(text);
    } on CsvParseException catch (e) {
      if (context.mounted) warnNotSaved(context, e.message);
      return;
    } catch (e) {
      if (context.mounted) warnNotSaved(context, 'that file could not be read: $e');
      return;
    }
    if (!context.mounted) return;

    final imported = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => ImportCsvScreen(
          sourceFilename: file.name,
          headers: table.headers,
          rawRows: table.rows,
        ),
      ),
    );
    if (imported == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Import complete')));
    }
  }

  Future<void> _exportCsv(BuildContext context, int profileId) async {
    final repo = ref.read(repositoryProvider);
    final stamp = DateTime.now().toIso8601String().split('T').first;
    final location = await getSaveLocation(
      suggestedName: 'clearly-transactions-$stamp.csv',
      acceptedTypeGroups: const [
        XTypeGroup(label: 'CSV', extensions: ['csv']),
      ],
    );
    if (location == null) return;

    final csv = await repo.exportEntriesAsCsv(profileId: profileId);
    await File(location.path).writeAsString(csv);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Exported to ${location.path}')));
    }
  }

  Future<void> _showImportHistory(BuildContext context, int profileId) async {
    final repo = ref.read(repositoryProvider);
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Import history'),
        content: SizedBox(
          width: 420,
          child: StreamBuilder<List<ImportBatch>>(
            stream: repo.watchImportBatches(profileId: profileId),
            builder: (context, snap) {
              final batches = snap.data ?? [];
              if (batches.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('No imports yet.'),
                );
              }
              return SizedBox(
                height: 320,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final b in batches)
                      ListTile(
                        title: Text(b.sourceFilename),
                        subtitle: Text('${_fmtDate(b.importedAt)} • '
                            '${b.rowCount} ${b.rowCount == 1 ? 'row' : 'rows'}'
                            '${b.balanceAdjustmentCents != 0 ? ' • balance updated' : ''}'),
                        trailing: TextButton(
                          onPressed: () =>
                              _undoImportBatch(context, profileId, b),
                          child: const Text('Undo'),
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

  Future<void> _undoImportBatch(
      BuildContext context, int profileId, ImportBatch batch) async {
    final repo = ref.read(repositoryProvider);
    final hasEdits =
        await repo.importBatchHasDownstreamEdits(batchId: batch.id);
    if (!context.mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Undo this import?'),
        content: Text(
            '${batch.rowCount} ${batch.rowCount == 1 ? 'transaction' : 'transactions'} '
            'from "${batch.sourceFilename}" will be removed'
            '${batch.balanceAdjustmentCents != 0 ? ', and the balance change it made will be reversed' : ''}.'
            '${hasEdits ? '\n\nSome of these transactions have since been split '
                    'or tagged — that will be lost too.' : ''}'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Undo import')),
        ],
      ),
    );
    if (ok != true) return;

    await repo.undoImportBatch(profileId: profileId, batchId: batch.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Import undone')));
    }
  }
}
