/// A category for a merchant category code (MCC), the four digit code card
/// networks attach to every merchant. Banks that pass it along give a far
/// better signal than the free-text description.
///
/// Used only when none of the person's own category rules match, so their
/// rules always win. Names are plain and common (Groceries, Dining) because
/// categories in Clearly are free text; an MCC never maps to a name nobody
/// would recognise.
String? categoryForMcc(String? mcc) {
  final code = int.tryParse((mcc ?? '').trim());
  if (code == null) return null;
  for (final r in _ranges) {
    if (code >= r.$1 && code <= r.$2) return r.$3;
  }
  return null;
}

const _ranges = <(int, int, String)>[
  // Food.
  (5411, 5411, 'Groceries'),
  (5422, 5422, 'Groceries'),
  (5441, 5441, 'Groceries'),
  (5451, 5451, 'Groceries'),
  (5462, 5462, 'Groceries'),
  (5499, 5499, 'Groceries'),
  (5811, 5814, 'Dining'),
  // Getting around.
  (5541, 5542, 'Gas'),
  (5983, 5983, 'Gas'),
  (4111, 4131, 'Transportation'),
  (4784, 4784, 'Transportation'),
  (4789, 4789, 'Transportation'),
  (7523, 7523, 'Transportation'),
  (5511, 5599, 'Auto'),
  (7531, 7549, 'Auto'),
  // Travel.
  (3000, 3299, 'Travel'),
  (3500, 3999, 'Travel'),
  (4511, 4511, 'Travel'),
  (4722, 4722, 'Travel'),
  (7011, 7011, 'Travel'),
  (7512, 7519, 'Travel'),
  // Bills.
  (4814, 4816, 'Utilities'),
  (4899, 4899, 'Utilities'),
  (4900, 4900, 'Utilities'),
  (6300, 6399, 'Insurance'),
  // Health and care.
  (5912, 5912, 'Health'),
  (8011, 8099, 'Health'),
  (7230, 7299, 'Personal care'),
  (7941, 7941, 'Fitness'),
  (7997, 7997, 'Fitness'),
  // Fun.
  (5815, 5818, 'Entertainment'),
  (7832, 7841, 'Entertainment'),
  (7911, 7999, 'Entertainment'),
  (5968, 5968, 'Subscriptions'),
  // Shopping and home.
  (5200, 5271, 'Home'),
  (5712, 5722, 'Home'),
  (5300, 5399, 'Shopping'),
  (5600, 5699, 'Shopping'),
  (5900, 5999, 'Shopping'),
  // Everything else with a clear meaning.
  (8211, 8299, 'Education'),
  (6010, 6012, 'Cash'),
  (9211, 9399, 'Taxes & fees'),
];
