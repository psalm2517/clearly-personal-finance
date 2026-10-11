/// A category guessed from the wording of a bank statement line, for the
/// common merchants that show up on everyone's statements. It is the last
/// resort: the person's own rules come first, then the merchant category
/// code when the bank provides one. Only plain, widely recognised names are
/// matched, so a guess is never a stretch. Anything unrecognised stays
/// "Other" for the person to categorize.
String? categoryForDescription(String? description) {
  final text = (description ?? '').toLowerCase();
  if (text.isEmpty) return null;
  for (final rule in _rules) {
    if (rule.$1.hasMatch(text)) return rule.$2;
  }
  return null;
}

/// Trades and cash sweeps inside a brokerage or retirement account. Money
/// changing form inside the account is not spending or income, so these are
/// kept out of the budget.
final brokerageActivity = RegExp(
  r'you bought|you sold|purchase into core|redemption from core|'
  r'reinvestment|sweep|dividend reinvest|exchange in|exchange out',
  caseSensitive: false,
);

final _rules = <(RegExp, String)>[
  // Eating out and delivery.
  (
    RegExp(
      r"uber\s*\*?\s*eats|ubereats|doordash|grubhub|postmates|dunkin|"
      r"domino|chipotle|mcdonald|wingstop|starbucks|taco bell|burger|pizza|"
      r"wendy|chick-fil|panera|popeyes|kfc|in-n-out|smoothie|cafe\b|"
      r"coffee|\bsubway\b|dine|restaurant|diner|bakery|deli\b|sushi|"
      r"klarna\*uber eats",
    ),
    'Dining',
  ),
  // Food shopping.
  (
    RegExp(
      r'grocer|food universe|supermarket|whole foods|trader joe|kroger|'
      r'safeway|aldi|publix|wegmans|costco|instacart|7-eleven|7 eleven',
    ),
    'Groceries',
  ),
  // Fuel.
  (
    RegExp(
      r'\bbp\b|shell oil|exxon|chevron|sunoco|mobil\b|citgo|gulf oil|'
      r'wawa|speedway|fuel',
    ),
    'Gas',
  ),
  // Getting around.
  (
    RegExp(
      r'uber\s*\*?\s*trip|uber trip|lyft|\bmta\b|nyct|paygo|metrocard|'
      r'omny|transit|amtrak|parking|\btoll|e-zpass|ezpass',
    ),
    'Transportation',
  ),
  // Phone, internet.
  (
    RegExp(
      r't-mobile|metro by|\bvisible\b|verizon|at&t|comcast|xfinity|spectrum|'
      r'cricket wireless|mint mobile|google fi|hetzner',
    ),
    'Utilities',
  ),
  // Insurance.
  (
    RegExp(
      r'insurance|\bins\b|geico|allstate|state farm|progressive|'
      r'lemonade|renters|condo ins',
    ),
    'Insurance',
  ),
  // Subscriptions and software.
  (
    RegExp(
      r'spotify|netflix|hulu|disney\+|disneyplus|hbo|youtube|'
      r'apple\.com/bill|icloud|anthropic|openai|chatgpt|claude|openrouter|'
      r'discord|github|dropbox|adobe|patreon|substack|nitro',
    ),
    'Subscriptions',
  ),
  // Games and entertainment.
  (
    RegExp(r'steam|playstation|xbox|nintendo|epic games|twitch|cinema|\bamc\b'),
    'Entertainment',
  ),
  // Health and pets.
  (
    RegExp(
      r'pharmacy|cvs|walgreens|rite aid|dental|clinic|medical|petco|'
      r'petsmart|vet\b',
    ),
    'Health',
  ),
  // Shopping.
  (
    RegExp(
      r'amazon|amzn|target\b|walmart|best buy|ikea|etsy|ebay|'
      r'apple store|nike|zara|h&m|david yurman|aplpay store',
    ),
    'Shopping',
  ),
  // Money moving to people or between banks.
  (RegExp(r'zelle|venmo|cash app|paypal'), 'Peer payments'),
  (RegExp(r'transfer|xfer|\bdb-bkrg\b|wefunder'), 'Transfers'),
  // Payments on cards and loans that were not recognised as one of yours.
  (RegExp(r'payment|pymt|\bpmt\b'), 'Payments'),
];
