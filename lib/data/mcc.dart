import 'categories.dart';

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

final _ranges = <(int, int, String)>[
  // Food.
  (5411, 5411, Cat.groceries),
  (5422, 5422, Cat.groceries),
  (5441, 5441, Cat.groceries),
  (5451, 5451, Cat.groceries),
  (5462, 5462, Cat.groceries),
  (5499, 5499, Cat.groceries),
  (5811, 5814, Cat.food),
  // Getting around.
  (5541, 5542, Cat.auto),
  (5983, 5983, Cat.auto),
  (4111, 4131, Cat.auto),
  (4784, 4784, Cat.auto),
  (4789, 4789, Cat.auto),
  (7523, 7523, Cat.auto),
  (5511, 5599, Cat.auto),
  (7531, 7549, Cat.auto),
  // Travel.
  (3000, 3299, Cat.travel),
  (3500, 3999, Cat.travel),
  (4511, 4511, Cat.travel),
  (4722, 4722, Cat.travel),
  (7011, 7011, Cat.travel),
  (7512, 7519, Cat.travel),
  // Bills.
  (4814, 4816, Cat.utilities),
  (4899, 4899, Cat.utilities),
  (4900, 4900, Cat.utilities),
  (6300, 6399, Cat.financial),
  // Health and care.
  (5912, 5912, Cat.medical),
  (8011, 8099, Cat.medical),
  (7230, 7299, Cat.personal),
  (7941, 7941, Cat.personal),
  (7997, 7997, Cat.personal),
  // Fun.
  (5815, 5818, Cat.entertainment),
  (7832, 7841, Cat.entertainment),
  (7911, 7999, Cat.entertainment),
  (5968, 5968, Cat.subscriptions),
  // Shopping and home.
  (5200, 5271, Cat.housing),
  (5712, 5722, Cat.housing),
  (5300, 5399, Cat.personal),
  (5600, 5699, Cat.personal),
  (5900, 5999, Cat.personal),
  // Everything else with a clear meaning.
  (8211, 8299, Cat.education),
  (6010, 6012, Cat.financial),
  (9211, 9399, Cat.taxes),
];
