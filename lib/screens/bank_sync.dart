import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../data/simplefin.dart';
import '../main.dart';
import '../util/money.dart';
import '../widgets/common.dart';
import 'accounts.dart' show accountLabel;

/// The client the app talks to the Bridge with. A provider so tests can
/// swap in a scripted one instead of the network.
final simpleFinClientProvider = Provider<SimpleFinClient>(
  (ref) => SimpleFinClient(),
);

/// Optional bank sync through SimpleFIN. Nothing here is required: with no
/// connection Clearly works exactly as it does by hand.
class BankSyncSection extends ConsumerStatefulWidget {
  const BankSyncSection({super.key});

  @override
  ConsumerState<BankSyncSection> createState() => _BankSyncSectionState();
}

class _BankSyncSectionState extends ConsumerState<BankSyncSection> {
  bool _busy = false;

  HomebaseRepository get _repo => ref.read(repositoryProvider);
  int get _profileId => ref.read(activeProfileProvider)!.id;

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() => _busy = true);
    try {
      await work();
    } on SimpleFinException catch (e) {
      _toast(e.message);
    } on StateError catch (e) {
      _toast(e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connect() async {
    final token = await showDialog<String>(
      context: context,
      builder: (_) => const _TokenDialog(),
    );
    if (token == null) return;
    await _run(() async {
      await _repo.connectSimpleFin(
        profileId: _profileId,
        setupToken: token,
        client: ref.read(simpleFinClientProvider),
      );
      _toast('Connected. Choose where each account belongs below.');
    });
  }

  Future<void> _sync({Duration? lookback}) => _run(() async {
    final r = await _repo.syncSimpleFin(
      profileId: _profileId,
      client: ref.read(simpleFinClientProvider),
      lookback: lookback,
    );
    if (r.failure != null) {
      _toast(r.failure!);
    } else if (r.messages.isNotEmpty) {
      _toast(r.messages.join('\n'));
    } else {
      _toast(
        r.newTransactions == 0
            ? 'Up to date.'
            : '${r.newTransactions} new transactions.',
      );
    }
  });

  Future<void> _disconnect(SimpleFinConnection c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disconnect SimpleFIN?'),
        content: const Text(
          'Clearly stops syncing. Your accounts and every transaction '
          'already imported stay exactly as they are. You can connect '
          'again later with a new setup token.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _run(
      () =>
          _repo.disconnectSimpleFin(profileId: _profileId, connectionId: c.id),
    );
  }

  Future<void> _createFrom(
    SimpleFinFeedAccount f,
    FeedTarget kind, [
    AccountType type = AccountType.checking,
  ]) => _run(() async {
    await _repo.createFromSimpleFinAccount(
      profileId: _profileId,
      feedAccountId: f.id,
      kind: kind,
      accountType: type,
    );
    // A newly linked account should arrive with its recent history.
    await _repo.syncSimpleFin(
      profileId: _profileId,
      client: ref.read(simpleFinClientProvider),
      lookback: const Duration(days: 90),
    );
  });

  Future<void> _linkExisting(SimpleFinFeedAccount f) async {
    final accounts = await _repo.watchAccounts(profileId: _profileId).first;
    final cards = await _repo.watchCards(profileId: _profileId).first;
    final loans = await _repo.watchLoans(profileId: _profileId).first;
    if (!mounted) return;
    final pick = await showDialog<(FeedTarget, int)>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Link "${f.name}" to'),
        children: [
          if (accounts.isEmpty && cards.isEmpty && loans.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Nothing to link to yet. Add it as new instead.'),
            ),
          for (final a in accounts)
            SimpleDialogOption(
              onPressed: () =>
                  Navigator.pop(context, (FeedTarget.account, a.id)),
              child: Text('${a.name}  ·  ${accountLabel(a.type)}'),
            ),
          for (final c in cards)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, (FeedTarget.card, c.id)),
              child: Text('${c.name}  ·  Credit card'),
            ),
          for (final l in loans)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, (FeedTarget.loan, l.id)),
              child: Text('${l.name}  ·  Loan'),
            ),
        ],
      ),
    );
    if (pick == null) return;
    await _run(() async {
      await _repo.linkSimpleFinAccount(
        profileId: _profileId,
        feedAccountId: f.id,
        target: pick.$1,
        targetId: pick.$2,
      );
      await _repo.syncSimpleFin(
        profileId: _profileId,
        client: ref.read(simpleFinClientProvider),
        lookback: const Duration(days: 90),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final profileId = ref.watch(activeProfileProvider)!.id;
    final scheme = Theme.of(context).colorScheme;

    return StreamBuilder<List<Object>>(
      stream: combineLatest<Object>([
        repo.watchSimpleFinConnections(profileId: profileId),
        repo.watchSimpleFinFeedAccounts(profileId: profileId),
      ]),
      builder: (context, snap) {
        final data = snap.data;
        final connections = data == null
            ? const <SimpleFinConnection>[]
            : data[0] as List<SimpleFinConnection>;
        final feed = data == null
            ? const <SimpleFinFeedAccount>[]
            : data[1] as List<SimpleFinFeedAccount>;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SectionHeader(
              'Bank sync',
              icon: Icons.sync_outlined,
              info: const InfoButton(
                title: 'How bank sync works',
                body: [
                  'Clearly reads your accounts through SimpleFIN, an '
                      'independent service that gives apps a read-only feed. '
                      'Your bank login stays with SimpleFIN. Clearly only '
                      'ever receives balances and transactions.',
                  'SimpleFIN is a separate service that you pay directly, '
                      '\$1.50 a month or \$15 a year. Clearly does not charge '
                      'for it.',
                  'Accounts that appear in the feed are not imported until '
                      'you decide where each one belongs, so nothing lands '
                      'in the wrong place.',
                  'Balances follow what the bank reports. Transactions are '
                      'imported once each, and every sync can be undone as '
                      'a batch from the import history.',
                  'The SimpleFIN Bridge allows about 24 refreshes a day, so '
                      'syncing is not meant to be instant.',
                  'This is optional. Without it, everything works by hand.',
                ],
              ),
            ),
            Card(
              child: connections.isEmpty
                  ? ListTile(
                      leading: const Icon(Icons.link_outlined),
                      title: const Text('Connect SimpleFIN'),
                      subtitle: const Text(
                        'Pull balances and transactions in automatically',
                      ),
                      trailing: FilledButton(
                        onPressed: _busy ? null : _connect,
                        child: const Text('Connect'),
                      ),
                    )
                  : Column(
                      children: [
                        for (final c in connections) ...[
                          ListTile(
                            leading: const Icon(Icons.link_outlined),
                            title: Text(c.label),
                            subtitle: Text(_status(c)),
                            trailing: Wrap(
                              spacing: 8,
                              children: [
                                FilledButton.tonal(
                                  onPressed: _busy ? null : () => _sync(),
                                  child: const Text('Sync now'),
                                ),
                                TextButton(
                                  onPressed: _busy
                                      ? null
                                      : () => _disconnect(c),
                                  child: const Text('Disconnect'),
                                ),
                              ],
                            ),
                          ),
                          const Divider(height: 1),
                        ],
                        if (feed.isEmpty)
                          const Padding(
                            padding: EdgeInsets.all(16),
                            child: Text(
                              'No accounts reported yet. '
                              'Press Sync now.',
                            ),
                          ),
                        for (final f in feed)
                          _FeedRow(
                            feed: f,
                            busy: _busy,
                            scheme: scheme,
                            onCreate: (kind, [type]) => _createFrom(
                              f,
                              kind,
                              type ?? AccountType.checking,
                            ),
                            onLink: () => _linkExisting(f),
                            onIgnore: () =>
                                _run(() => _repo.ignoreSimpleFinAccount(f.id)),
                            onUnlink: () =>
                                _run(() => _repo.unlinkSimpleFinAccount(f.id)),
                          ),
                      ],
                    ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
          ],
        );
      },
    );
  }

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

  String _status(SimpleFinConnection c) {
    final at = c.lastSyncAt;
    final when = at == null
        ? 'Never synced'
        : 'Synced ${_months[at.month - 1]} ${at.day}, '
              '${at.hour % 12 == 0 ? 12 : at.hour % 12}:'
              '${at.minute.toString().padLeft(2, '0')} '
              '${at.hour < 12 ? 'AM' : 'PM'}';
    final msg = c.lastSyncMessage;
    return msg == null || msg.isEmpty ? when : '$when. $msg';
  }
}

class _FeedRow extends StatelessWidget {
  const _FeedRow({
    required this.feed,
    required this.busy,
    required this.scheme,
    required this.onCreate,
    required this.onLink,
    required this.onIgnore,
    required this.onUnlink,
  });

  final SimpleFinFeedAccount feed;
  final bool busy;
  final ColorScheme scheme;
  final void Function(FeedTarget kind, [AccountType? type]) onCreate;
  final VoidCallback onLink;
  final VoidCallback onIgnore;
  final VoidCallback onUnlink;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (feed.target) {
      FeedTarget.unmapped => ('Needs review', scheme.tertiary),
      FeedTarget.ignored => ('Ignored', scheme.onSurfaceVariant),
      FeedTarget.account => ('Account', scheme.primary),
      FeedTarget.card => ('Credit card', scheme.primary),
      FeedTarget.loan => ('Loan', scheme.primary),
    };
    return ListTile(
      title: Text(
        feed.name,
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        [
          if (feed.orgName != null) feed.orgName!,
          fmtCents(feed.balanceCents),
        ].join('  ·  '),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Pill(label, color: color),
          const SizedBox(width: 8),
          if (feed.target == FeedTarget.unmapped)
            PopupMenuButton<String>(
              enabled: !busy,
              tooltip: 'Choose where this belongs',
              onSelected: (v) {
                switch (v) {
                  case 'checking':
                    onCreate(FeedTarget.account, AccountType.checking);
                  case 'savings':
                    onCreate(FeedTarget.account, AccountType.savings);
                  case 'investment':
                    onCreate(FeedTarget.account, AccountType.investment);
                  case 'retirement':
                    onCreate(FeedTarget.account, AccountType.retirement);
                  case 'card':
                    onCreate(FeedTarget.card);
                  case 'loan':
                    onCreate(FeedTarget.loan);
                  case 'link':
                    onLink();
                  case 'ignore':
                    onIgnore();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'checking',
                  child: Text('Add as checking'),
                ),
                PopupMenuItem(value: 'savings', child: Text('Add as savings')),
                PopupMenuItem(
                  value: 'investment',
                  child: Text('Add as investment'),
                ),
                PopupMenuItem(
                  value: 'retirement',
                  child: Text('Add as retirement'),
                ),
                PopupMenuItem(value: 'card', child: Text('Add as credit card')),
                PopupMenuItem(value: 'loan', child: Text('Add as loan')),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'link',
                  child: Text('Link to an existing one…'),
                ),
                PopupMenuItem(value: 'ignore', child: Text('Ignore')),
              ],
            )
          else
            TextButton(
              onPressed: busy ? null : onUnlink,
              child: Text(
                feed.target == FeedTarget.ignored ? 'Review again' : 'Unlink',
              ),
            ),
        ],
      ),
    );
  }
}

class _TokenDialog extends StatefulWidget {
  const _TokenDialog();

  @override
  State<_TokenDialog> createState() => _TokenDialogState();
}

class _TokenDialogState extends State<_TokenDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    try {
      SimpleFinClient.claimUrlFromToken(_controller.text);
    } on SimpleFinException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Connect SimpleFIN'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Create a setup token at bridge.simplefin.org (it is a paid '
              'service, billed by SimpleFIN), then paste it here. A token '
              'works once.',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'Setup token',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Connect')),
      ],
    );
  }
}
