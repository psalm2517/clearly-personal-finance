import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The top-level places you can be, in sidebar order. Held in a provider so
/// anything can send you somewhere ("See cash flow") without knowing about
/// the shell.
enum Dest {
  dashboard('Dashboard'),
  accounts('Accounts'),
  transactions('Transactions'),
  cashFlow('Cash Flow'),
  budget('Budget'),
  recurring('Recurring'),
  settings('Settings');

  const Dest(this.title);
  final String title;
}

final navProvider = StateProvider<Dest>((ref) => Dest.dashboard);
