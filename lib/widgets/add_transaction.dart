import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../data/transaction_draft.dart';
import '../main.dart';
import '../screens/accounts.dart' show accountIcon, accountTypeColor;
import '../util/money.dart';
import 'common.dart';

/// The one way to record money: an expense, income, a transfer between your
/// own accounts, or a card/loan payment — once or repeating. Everything the
/// separate "add entry / add recurring / add transfer / log payment / add
/// schedule" buttons used to do goes through here, and
/// [HomebaseRepository.addTransaction] decides where it belongs.
///
/// With [existing] it edits that budget entry instead (kind and repeating
/// are fixed once it exists).
Future<void> showAddTransaction(
  BuildContext context,
  WidgetRef ref, {
  BudgetEntry? existing,
  DraftKind? kind,
}) async {
  final repo = ref.read(repositoryProvider);
  final profileId = ref.read(activeProfileProvider)!.id;
  final accounts = await repo.watchAccounts(profileId: profileId).first;
  final cards = await repo.watchCards(profileId: profileId).first;
  final loans = await repo.watchLoans(profileId: profileId).first;
  final targets = await repo.watchBudgetTargets(profileId: profileId).first;
  var splits = <TransactionSplit>[];
  var tags = <String>[];
  if (existing != null) {
    splits = await repo.splitsFor(entryId: existing.id);
    tags = (await repo.watchEntryTagNames(profileId: profileId).first)[
            existing.id] ??
        [];
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _AddTransactionDialog(
      ref: ref,
      profileId: profileId,
      accounts: accounts,
      cards: cards,
      loans: loans,
      targetCategories: [for (final t in targets) t.category],
      existing: existing,
      existingSplits: splits,
      existingTags: tags,
      initialKind: kind,
    ),
  );
}

String _label(PayFrequency f) => switch (f) {
      PayFrequency.weekly => 'Weekly',
      PayFrequency.biweekly => 'Bi-weekly',
      PayFrequency.semimonthly => 'Semi-monthly (1st & 15th style)',
      PayFrequency.monthly => 'Monthly',
    };

String _fmtDate(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  return '${months[d.month - 1]} ${ordinalDay(d.day)}, ${d.year}';
}

class _AddTransactionDialog extends StatefulWidget {
  const _AddTransactionDialog({
    required this.ref,
    required this.profileId,
    required this.accounts,
    required this.cards,
    required this.loans,
    required this.targetCategories,
    required this.existing,
    required this.existingSplits,
    required this.existingTags,
    required this.initialKind,
  });

  final WidgetRef ref;
  final int profileId;
  final List<Account> accounts;
  final List<CreditCard> cards;
  final List<Loan> loans;
  final List<String> targetCategories;
  final BudgetEntry? existing;
  final List<TransactionSplit> existingSplits;
  final List<String> existingTags;
  final DraftKind? initialKind;

  @override
  State<_AddTransactionDialog> createState() => _AddTransactionDialogState();
}

class _AddTransactionDialogState extends State<_AddTransactionDialog> {
  late DraftKind _kind;
  final _amount = TextEditingController();
  final _name = TextEditingController();
  final _category = TextEditingController();
  final _payee = TextEditingController();
  final _tags = TextEditingController();
  final _note = TextEditingController();
  late DateTime _date;
  var _repeats = false;
  var _frequency = PayFrequency.monthly;
  var _autoCategorized = false;
  var _saving = false;
  String? _error;

  // "account:3" / "card:2" for income and expense.
  String? _source;
  int? _fromAccountId;
  int? _toAccountId;
  String? _targetCategory;
  // "card:2" / "loan:1" for a payment.
  String? _payable;
  int? _paidFromId;

  var _splitMode = false;
  final _splitRows =
      <({TextEditingController category, TextEditingController amount})>[];

  bool get _editing => widget.existing != null;
  DateTime get _today {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  bool get _isEntry => _kind == DraftKind.expense || _kind == DraftKind.income;
  bool get _canRepeat => !_editing && _kind != DraftKind.payment;

  List<Account> get _cashAccounts => [
        for (final a in widget.accounts)
          if (HomebaseRepository.cashAccountTypes.contains(a.type) ||
              a.id == widget.existing?.accountId)
            a
      ];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _date = _today;
    if (e != null) {
      _kind = e.type == EntryType.income ? DraftKind.income : DraftKind.expense;
      _amount.text = (e.amountCents / 100).toString();
      _name.text = e.description ?? '';
      _category.text = e.category == 'Split' ? '' : e.category;
      _payee.text = e.payee ?? '';
      _tags.text = widget.existingTags.join(', ');
      _date = DateTime(e.date.year, e.date.month, e.date.day);
      _source = e.accountId != null
          ? 'account:${e.accountId}'
          : e.cardId != null
              ? 'card:${e.cardId}'
              : null;
      if (widget.existingSplits.isNotEmpty) {
        _splitMode = true;
        for (final s in widget.existingSplits) {
          _splitRows.add((
            category: TextEditingController(text: s.category),
            amount:
                TextEditingController(text: (s.amountCents / 100).toString()),
          ));
        }
      }
    } else {
      _kind = widget.initialKind ?? DraftKind.expense;
    }
    if (_kind == DraftKind.payment) _defaultPayable();
    if (widget.accounts.length >= 2) {
      _fromAccountId = widget.accounts[0].id;
      _toAccountId = widget.accounts[1].id;
    }
  }

  @override
  void dispose() {
    for (final c in [_amount, _name, _category, _payee, _tags, _note]) {
      c.dispose();
    }
    for (final r in _splitRows) {
      r.category.dispose();
      r.amount.dispose();
    }
    super.dispose();
  }

  int? get _cents => parseDollarsToCents(_amount.text);
  bool get _valid => (_cents ?? 0) > 0;

  void _defaultPayable() {
    if (_payable != null) return;
    if (widget.cards.isNotEmpty) {
      _payable = 'card:${widget.cards.first.id}';
    } else if (widget.loans.isNotEmpty) {
      _payable = 'loan:${widget.loans.first.id}';
    }
  }

  void _setKind(DraftKind k) => setState(() {
        _kind = k;
        _error = null;
        if (k == DraftKind.payment) _defaultPayable();
        if (!_canRepeat) _repeats = false;
        // A card can't receive repeating income.
        if (_kind == DraftKind.income &&
            _repeats &&
            (_source?.startsWith('card:') ?? false)) {
          _source = null;
        }
      });

  Future<void> _save() async {
    if (!_valid || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final repo = widget.ref.read(repositoryProvider);
    try {
      if (_editing) {
        await _saveEdit(repo);
      } else {
        await repo.addTransaction(
            profileId: widget.profileId, draft: _draft());
      }
      if (mounted) Navigator.pop(context);
    } on ArgumentError catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message.toString();
          _saving = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Could not save: $e';
          _saving = false;
        });
      }
    }
  }

  TransactionDraft _draft() {
    final src = _source?.split(':');
    final pay = _payable?.split(':');
    return TransactionDraft(
      kind: _kind,
      amountCents: _cents ?? 0,
      date: _date,
      name: _name.text,
      category: _category.text,
      payee: _payee.text,
      tags: [
        for (final t in _tags.text.split(','))
          if (t.trim().isNotEmpty) t.trim()
      ],
      splits: _splitMode && _isEntry && !_repeats
          ? [
              for (final r in _splitRows)
                if (r.category.text.trim().isNotEmpty)
                  (
                    category: r.category.text.trim(),
                    amountCents: parseDollarsToCents(r.amount.text) ?? 0,
                  ),
            ]
          : const [],
      accountId: switch (_kind) {
        DraftKind.transfer => _fromAccountId,
        DraftKind.payment => _paidFromId,
        _ => src != null && src[0] == 'account' ? int.parse(src[1]) : null,
      },
      cardId: _isEntry && src != null && src[0] == 'card'
          ? int.parse(src[1])
          : null,
      toAccountId: _kind == DraftKind.transfer ? _toAccountId : null,
      payableType: pay == null
          ? null
          : pay[0] == 'card'
              ? PaymentAccountType.card
              : PaymentAccountType.loan,
      payableId: pay == null ? null : int.parse(pay[1]),
      targetCategory: _kind == DraftKind.transfer ? _targetCategory : null,
      note: _note.text,
      repeats: _repeats,
      frequency: _frequency,
    );
  }

  Future<void> _saveEdit(HomebaseRepository repo) async {
    final existing = widget.existing!;
    final cents = _cents!;
    final src = _source?.split(':');
    var splits = <({String category, int amountCents})>[];
    if (_splitMode) {
      splits = [
        for (final r in _splitRows)
          if (r.category.text.trim().isNotEmpty)
            (
              category: r.category.text.trim(),
              amountCents: parseDollarsToCents(r.amount.text) ?? 0,
            ),
      ];
      if (splits.isEmpty ||
          splits.fold(0, (s, r) => s + r.amountCents) != cents) {
        throw ArgumentError('splits must add up to the total amount');
      }
    }
    await repo.updateBudgetEntry(
      profileId: widget.profileId,
      id: existing.id,
      entry: BudgetEntriesCompanion(
        date: Value(_date),
        amountCents: Value(cents),
        type: Value(_kind == DraftKind.income
            ? EntryType.income
            : EntryType.expense),
        category: Value(_splitMode
            ? 'Split'
            : _category.text.trim().isEmpty
                ? 'Other'
                : _category.text.trim()),
        description:
            Value(_name.text.trim().isEmpty ? null : _name.text.trim()),
        payee: Value(_payee.text.trim().isEmpty ? null : _payee.text.trim()),
        accountId: Value(
            src != null && src[0] == 'account' ? int.parse(src[1]) : null),
        cardId:
            Value(src != null && src[0] == 'card' ? int.parse(src[1]) : null),
      ),
    );
    // Set unconditionally, so turning splits or tags off actually clears them.
    await repo.setEntrySplits(
        profileId: widget.profileId, entryId: existing.id, splits: splits);
    await repo.setEntryTags(
        profileId: widget.profileId,
        entryId: existing.id,
        tagNames: _tags.text.split(','));
  }

  Future<void> _pickDate() async {
    final last = _repeats ? DateTime(2060) : _today;
    final picked = await showDatePicker(
      context: context,
      initialDate: _date.isAfter(last) ? last : _date,
      firstDate: DateTime(2020),
      lastDate: last,
      helpText: _repeats ? 'First occurrence' : 'Date',
    );
    if (picked != null) setState(() => _date = picked);
  }

  Widget _accountItemRow(Account a) => Row(children: [
        Icon(accountIcon(a.type),
            size: 16, color: accountTypeColor(context, a.type)),
        const SizedBox(width: 8),
        Text(a.name),
      ]);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final repo = widget.ref.read(repositoryProvider);

    // Income that repeats is a paycheck deposited to an account, so a card
    // isn't offered for it.
    final entryAccounts = _cashAccounts;
    final entryCards =
        _kind == DraftKind.income && _repeats ? <CreditCard>[] : widget.cards;

    return SubmitOnEnter(
      onSubmit: _save,
      child: AlertDialog(
        title: Text(_editing ? 'Edit entry' : 'Add'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_editing)
                SegmentedButton<DraftKind>(
                  segments: const [
                    ButtonSegment(
                        value: DraftKind.expense, label: Text('Expense')),
                    ButtonSegment(
                        value: DraftKind.income, label: Text('Income')),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => _setKind(s.first),
                )
              else
                SegmentedButton<DraftKind>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                        value: DraftKind.expense, label: Text('Expense')),
                    ButtonSegment(
                        value: DraftKind.income, label: Text('Income')),
                    ButtonSegment(
                        value: DraftKind.transfer, label: Text('Transfer')),
                    ButtonSegment(
                        value: DraftKind.payment, label: Text('Payment')),
                  ],
                  selected: {_kind},
                  onSelectionChanged: (s) => _setKind(s.first),
                ),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _amount,
                    autofocus: true,
                    onChanged: (_) => setState(() => _error = null),
                    decoration: const InputDecoration(
                        labelText: 'Amount (\$)',
                        border: OutlineInputBorder()),
                  ),
                ),
                if (_kind == DraftKind.payment && _payable != null) ...[
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: () {
                      final p = _payable!.split(':');
                      final id = int.parse(p[1]);
                      final balance = p[0] == 'card'
                          ? widget.cards.firstWhere((c) => c.id == id).balanceCents
                          : widget.loans.firstWhere((l) => l.id == id).balanceCents;
                      setState(() => _amount.text =
                          (balance / 100).toStringAsFixed(2));
                    },
                    child: const Text('Pay in full'),
                  ),
                ],
              ]),
              const SizedBox(height: 12),
              if (_isEntry) ...[
                TextField(
                  controller: _name,
                  decoration: InputDecoration(
                      labelText: _repeats ? 'Name' : 'Description',
                      border: const OutlineInputBorder()),
                  onChanged: (text) async {
                    final match = await repo.categorize(
                        profileId: widget.profileId,
                        description: text,
                        amountCents: _cents);
                    if (match != null &&
                        (_category.text.isEmpty || _autoCategorized) &&
                        mounted) {
                      setState(() {
                        _category.text = match;
                        _autoCategorized = true;
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                if (!_splitMode || _repeats)
                  TextField(
                    controller: _category,
                    onChanged: (_) => _autoCategorized = false,
                    decoration: InputDecoration(
                        labelText: 'Category',
                        helperText:
                            _autoCategorized ? 'Auto-categorized by rule' : null,
                        border: const OutlineInputBorder()),
                  ),
                if (!_repeats) ...[
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Split into categories'),
                    subtitle: const Text(
                        'Break this amount across more than one category'),
                    value: _splitMode,
                    onChanged: (v) => setState(() {
                      _splitMode = v;
                      if (v && _splitRows.isEmpty) {
                        for (var i = 0; i < 2; i++) {
                          _splitRows.add((
                            category: TextEditingController(),
                            amount: TextEditingController()
                          ));
                        }
                      }
                    }),
                  ),
                  if (_splitMode) ...[
                    for (var i = 0; i < _splitRows.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(children: [
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _splitRows[i].category,
                              decoration: const InputDecoration(
                                  labelText: 'Category',
                                  isDense: true,
                                  border: OutlineInputBorder()),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _splitRows[i].amount,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                  labelText: '\$',
                                  isDense: true,
                                  border: OutlineInputBorder()),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline,
                                size: 18),
                            onPressed: _splitRows.length <= 1
                                ? null
                                : () => setState(() => _splitRows.removeAt(i)),
                          ),
                        ]),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add split'),
                        onPressed: () => setState(() => _splitRows.add((
                              category: TextEditingController(),
                              amount: TextEditingController(),
                            ))),
                      ),
                    ),
                    Builder(builder: (context) {
                      final total = _cents ?? 0;
                      final splitTotal = _splitRows.fold<int>(
                          0,
                          (s, r) =>
                              s + (parseDollarsToCents(r.amount.text) ?? 0));
                      return Text(
                        '${fmtCents(splitTotal)} of ${fmtCents(total)} allocated',
                        style: TextStyle(
                            fontSize: 12,
                            color: splitTotal == total ? null : scheme.error),
                      );
                    }),
                    const SizedBox(height: 4),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                      controller: _payee,
                      decoration: const InputDecoration(
                          labelText: 'Payee (optional)',
                          border: OutlineInputBorder())),
                  const SizedBox(height: 12),
                  TextField(
                      controller: _tags,
                      decoration: const InputDecoration(
                          labelText: 'Tags (optional, comma separated)',
                          border: OutlineInputBorder())),
                ],
                if (entryAccounts.isNotEmpty || entryCards.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    key: ValueKey('source-$_kind-$_repeats'),
                    initialValue: _source,
                    decoration: InputDecoration(
                        labelText: _kind == DraftKind.income
                            ? 'Deposited to (optional)'
                            : 'Paid from (optional)',
                        helperText: 'Linking one moves its balance',
                        border: const OutlineInputBorder()),
                    items: [
                      const DropdownMenuItem(
                          value: null, child: Text('Not linked')),
                      for (final a in entryAccounts)
                        DropdownMenuItem(
                            value: 'account:${a.id}',
                            child: _accountItemRow(a)),
                      for (final c in entryCards)
                        DropdownMenuItem(
                          value: 'card:${c.id}',
                          child: Row(children: [
                            const Icon(Icons.credit_card, size: 16),
                            const SizedBox(width: 8),
                            Text(c.name),
                          ]),
                        ),
                    ],
                    onChanged: (v) => setState(() => _source = v),
                  ),
                ],
              ],
              if (_kind == DraftKind.transfer) ...[
                if (widget.accounts.length < 2)
                  Text('Add a second account first to move money between them.',
                      style: TextStyle(color: scheme.error))
                else ...[
                  TextField(
                    controller: _name,
                    decoration: const InputDecoration(
                        labelText: 'Name (optional)',
                        border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _fromAccountId,
                    decoration: const InputDecoration(
                        labelText: 'From', border: OutlineInputBorder()),
                    items: [
                      for (final a in widget.accounts)
                        DropdownMenuItem(
                            value: a.id, child: _accountItemRow(a)),
                    ],
                    onChanged: (v) => setState(() => _fromAccountId = v),
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    initialValue: _toAccountId,
                    decoration: const InputDecoration(
                        labelText: 'To', border: OutlineInputBorder()),
                    items: [
                      for (final a in widget.accounts)
                        DropdownMenuItem(
                            value: a.id, child: _accountItemRow(a)),
                    ],
                    onChanged: (v) => setState(() => _toAccountId = v),
                  ),
                  if (widget.targetCategories.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      initialValue: _targetCategory,
                      decoration: const InputDecoration(
                          labelText: 'Counts toward target (optional)',
                          helperText: 'Shows in that category\'s target on '
                              'the Budget screen, e.g. Invest or Save',
                          helperMaxLines: 2,
                          border: OutlineInputBorder()),
                      items: [
                        const DropdownMenuItem(
                            value: null, child: Text('None')),
                        for (final c in widget.targetCategories)
                          DropdownMenuItem(value: c, child: Text(c)),
                      ],
                      onChanged: (v) => setState(() => _targetCategory = v),
                    ),
                  ],
                ],
              ],
              if (_kind == DraftKind.payment) ...[
                if (widget.cards.isEmpty && widget.loans.isEmpty)
                  Text('Add a card or loan first to log a payment against it.',
                      style: TextStyle(color: scheme.error))
                else ...[
                  DropdownButtonFormField<String>(
                    initialValue: _payable,
                    decoration: const InputDecoration(
                        labelText: 'Paying', border: OutlineInputBorder()),
                    items: [
                      for (final c in widget.cards)
                        DropdownMenuItem(
                          value: 'card:${c.id}',
                          child: Row(children: [
                            const Icon(Icons.credit_card, size: 16),
                            const SizedBox(width: 8),
                            Text('${c.name} — ${fmtCents(c.balanceCents)}'),
                          ]),
                        ),
                      for (final l in widget.loans)
                        DropdownMenuItem(
                          value: 'loan:${l.id}',
                          child: Row(children: [
                            const Icon(Icons.request_quote_outlined, size: 16),
                            const SizedBox(width: 8),
                            Text('${l.name} — ${fmtCents(l.balanceCents)}'),
                          ]),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      _payable = v;
                      final p = v!.split(':');
                      if (p[0] == 'loan' && _amount.text.trim().isEmpty) {
                        final loan = widget.loans
                            .firstWhere((l) => l.id == int.parse(p[1]));
                        if (loan.monthlyPaymentCents > 0) {
                          _amount.text = (loan.monthlyPaymentCents / 100)
                              .toStringAsFixed(2);
                        }
                      }
                    }),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _note,
                    decoration: const InputDecoration(
                        labelText: 'Note (optional)',
                        border: OutlineInputBorder()),
                  ),
                  if (_cashAccounts.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<int?>(
                      initialValue: _paidFromId,
                      decoration: const InputDecoration(
                          labelText: 'Paid from (optional)',
                          helperText: 'Also deducts this amount from the '
                              'account\'s balance',
                          border: OutlineInputBorder()),
                      items: [
                        const DropdownMenuItem(
                            value: null, child: Text('Not linked')),
                        for (final a in _cashAccounts)
                          DropdownMenuItem(
                              value: a.id, child: _accountItemRow(a)),
                      ],
                      onChanged: (v) => setState(() => _paidFromId = v),
                    ),
                  ],
                ],
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.calendar_today, size: 16),
                  label: Text(_repeats
                      ? 'Starts ${_fmtDate(_date)}'
                      : _fmtDate(_date)),
                  onPressed: _pickDate,
                ),
              ),
              if (_canRepeat) ...[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Repeats'),
                  subtitle: Text(_kind == DraftKind.income
                      ? 'Set up as a paycheck schedule'
                      : _kind == DraftKind.transfer
                          ? 'Moves the money on a schedule'
                          : 'Posts itself on a schedule'),
                  value: _repeats,
                  onChanged: (v) => setState(() {
                    _repeats = v;
                    _error = null;
                    if (v &&
                        _kind == DraftKind.income &&
                        (_source?.startsWith('card:') ?? false)) {
                      _source = null;
                    }
                  }),
                ),
                if (_repeats) ...[
                  DropdownButtonFormField<PayFrequency>(
                    initialValue: _frequency,
                    decoration: const InputDecoration(
                        labelText: 'How often',
                        helperText: 'Every occurrence from the start date up '
                            'to today is posted right away',
                        helperMaxLines: 2,
                        border: OutlineInputBorder()),
                    items: [
                      for (final f in PayFrequency.values)
                        DropdownMenuItem(value: f, child: Text(_label(f))),
                    ],
                    onChanged: (v) => setState(() => _frequency = v!),
                  ),
                ],
              ],
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(_error!, style: TextStyle(color: scheme.error)),
                  ),
                ),
            ]),
          ),
        ),
        actions: [
          TextButton(
              onPressed: _saving ? null : () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: _valid && !_saving ? _save : null,
              child: Text(_editing ? 'Save changes' : 'Save')),
        ],
      ),
    );
  }
}
