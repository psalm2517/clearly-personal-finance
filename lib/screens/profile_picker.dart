import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../main.dart';
import '../util/pin.dart';

/// The name and tagline, in type only. There is deliberately no mark here
/// until Clearly has a real logo.
class _Wordmark extends StatelessWidget {
  const _Wordmark({this.size = 52});
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Clearly',
          style: TextStyle(
            fontSize: size,
            fontWeight: FontWeight.w700,
            letterSpacing: -1.5,
            height: 1,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'See clearly.',
          style: TextStyle(
            fontSize: 16,
            letterSpacing: 0.4,
            color: scheme.primary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

/// One line under the profile card saying what kind of app this is.
class _Promise extends StatelessWidget {
  const _Promise();

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return Text(
      'Free and open source  ·  Your data stays on this computer',
      textAlign: TextAlign.center,
      style: TextStyle(color: muted, fontSize: 13),
    );
  }
}

/// First run: create the two profiles. After that: pick a profile and enter
/// its PIN (if set). Non-admins land straight in their own data; the
/// visibility rule lives in AppShell (only admins get a switcher).
class ProfilePickerScreen extends ConsumerWidget {
  const ProfilePickerScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    return Scaffold(
      body: FutureBuilder(
        future: repo.allProfiles(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final profiles = snapshot.data!;
          if (profiles.isEmpty) return const _FirstRunSetup();
          return _Picker(profiles: profiles);
        },
      ),
    );
  }
}

class _Picker extends ConsumerWidget {
  const _Picker({required this.profiles});
  final List<Profile> profiles;

  Future<void> _select(
    BuildContext context,
    WidgetRef ref,
    Profile profile,
  ) async {
    if (profile.pinHash != null) {
      final ok = await _askPin(context, profile);
      if (!ok) return;
    }
    ref.read(loggedInProfileProvider.notifier).state = profile;
  }

  Future<bool> _askPin(BuildContext context, Profile profile) async {
    final controller = TextEditingController();
    String? error;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text('PIN for ${profile.name}'),
          content: TextField(
            controller: controller,
            obscureText: true,
            autofocus: true,
            decoration: InputDecoration(labelText: 'PIN', errorText: error),
            onSubmitted: (_) {
              if (verifyPin(controller.text, profile.pinHash!)) {
                Navigator.pop(context, true);
              } else {
                setState(() => error = 'Wrong PIN');
              }
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (verifyPin(controller.text, profile.pinHash!)) {
                  Navigator.pop(context, true);
                } else {
                  setState(() => error = 'Wrong PIN');
                }
              },
              child: const Text('Enter'),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final single = profiles.length == 1;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _Wordmark(),
            const SizedBox(height: 56),
            Text(
              single ? 'Welcome back' : 'Who is this?',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: scheme.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.center,
              children: [
                for (final p in profiles)
                  Padding(
                    padding: const EdgeInsets.all(10),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(18),
                      onTap: () => _select(context, ref, p),
                      child: Card(
                        margin: EdgeInsets.zero,
                        child: SizedBox(
                          width: 176,
                          height: 176,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              CircleAvatar(
                                radius: 36,
                                backgroundColor: scheme.primary.withValues(
                                  alpha: 0.18,
                                ),
                                foregroundColor: scheme.primary,
                                child: Text(
                                  p.name.characters.first.toUpperCase(),
                                  style: const TextStyle(
                                    fontSize: 28,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                p.name,
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              if (p.pinHash != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: Icon(
                                    Icons.lock_outline,
                                    size: 16,
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 48),
            const _Promise(),
          ],
        ),
      ),
    );
  }
}

/// First run creates only the admin profile. Everyone else is added later
/// from the admin's Profiles screen.
class _FirstRunSetup extends ConsumerStatefulWidget {
  const _FirstRunSetup();

  @override
  ConsumerState<_FirstRunSetup> createState() => _FirstRunSetupState();
}

class _FirstRunSetupState extends ConsumerState<_FirstRunSetup> {
  final _name = TextEditingController();
  final _pin = TextEditingController();
  bool _busy = false;

  Future<void> _create() async {
    if (_name.text.trim().isEmpty) return;
    setState(() => _busy = true);
    final repo = ref.read(repositoryProvider);
    final id = await repo.createProfile(
      ProfilesCompanion.insert(
        name: _name.text.trim(),
        isAdmin: const Value(true),
        pinHash: Value(_pin.text.isEmpty ? null : hashPin(_pin.text)),
      ),
    );
    final profile = await repo.profileById(id);
    if (!mounted || profile == null) return;
    ref.read(loggedInProfileProvider.notifier).state = profile;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Center(child: _Wordmark(size: 60)),
              const SizedBox(height: 40),
              Text(
                'Welcome to Clearly',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'Personal finance, kept simple. Track your accounts, budget, '
                'bills and cash flow in one place, with everything stored on '
                'this computer.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, height: 1.45),
              ),
              const SizedBox(height: 28),
              Card(
                margin: EdgeInsets.zero,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextField(
                        controller: _name,
                        autofocus: true,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          labelText: 'What should we call you?',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _pin,
                        obscureText: true,
                        onSubmitted: (_) => _busy ? null : _create(),
                        decoration: const InputDecoration(
                          labelText: 'PIN (optional)',
                          helperText:
                              'A PIN keeps other people on this computer out '
                              'of your profile. It is not encryption.',
                          helperMaxLines: 2,
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 20),
                      FilledButton(
                        onPressed: _busy ? null : _create,
                        child: const Padding(
                          padding: EdgeInsets.symmetric(vertical: 6),
                          child: Text('Get started'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'This profile is the admin. You can add others later for '
                'your household, each with their own data.',
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 32),
              const _Promise(),
            ],
          ),
        ),
      ),
    );
  }
}
