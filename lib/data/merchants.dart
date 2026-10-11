import 'categories.dart';

/// Trades and cash sweeps inside a brokerage or retirement account. Money
/// changing form inside the account is not spending or income, so these are
/// kept out of the budget. This is about accounting, not categories.
final brokerageActivity = RegExp(
  r'you bought|you sold|purchase into core|redemption from core|'
  r'reinvestment|sweep|dividend reinvest|exchange in|exchange out|'
  r'cash contribution',
  caseSensitive: false,
);

/// A rule Clearly can offer to add: text to look for and the category it
/// would send matches to.
///
/// Nothing here is applied on its own. Categorizing is the person's own
/// rules; these are only a starting point they can choose from.
class SuggestedRule {
  const SuggestedRule(this.keyword, this.category);
  final String keyword;
  final String category;
}

const suggestedRules = <SuggestedRule>[
  // Food & Dining
  SuggestedRule('uber eats', Cat.food),
  SuggestedRule('doordash', Cat.food),
  SuggestedRule('grubhub', Cat.food),
  SuggestedRule('dunkin', Cat.food),
  SuggestedRule('domino', Cat.food),
  SuggestedRule('chipotle', Cat.food),
  SuggestedRule('mcdonald', Cat.food),
  SuggestedRule('starbucks', Cat.food),
  SuggestedRule('wingstop', Cat.food),
  SuggestedRule('subway', Cat.food),
  // Groceries
  SuggestedRule('grocery', Cat.groceries),
  SuggestedRule('whole foods', Cat.groceries),
  SuggestedRule('trader joe', Cat.groceries),
  SuggestedRule('kroger', Cat.groceries),
  SuggestedRule('safeway', Cat.groceries),
  SuggestedRule('costco', Cat.groceries),
  SuggestedRule('instacart', Cat.groceries),
  // Transportation (gas included)
  SuggestedRule('uber trip', Cat.auto),
  SuggestedRule('lyft', Cat.auto),
  SuggestedRule('mta', Cat.auto),
  SuggestedRule('paygo', Cat.auto),
  SuggestedRule('shell oil', Cat.auto),
  SuggestedRule('exxon', Cat.auto),
  SuggestedRule('chevron', Cat.auto),
  SuggestedRule('sunoco', Cat.auto),
  SuggestedRule('e-zpass', Cat.auto),
  // Utilities & Bills
  SuggestedRule('t-mobile', Cat.utilities),
  SuggestedRule('verizon', Cat.utilities),
  SuggestedRule('comcast', Cat.utilities),
  SuggestedRule('xfinity', Cat.utilities),
  SuggestedRule('spectrum', Cat.utilities),
  // Financial Services
  SuggestedRule('geico', Cat.financial),
  SuggestedRule('allstate', Cat.financial),
  SuggestedRule('state farm', Cat.financial),
  SuggestedRule('progressive', Cat.financial),
  // Subscriptions & Software
  SuggestedRule('spotify', Cat.entertainment),
  SuggestedRule('netflix', Cat.entertainment),
  SuggestedRule('hulu', Cat.entertainment),
  SuggestedRule('youtube', Cat.entertainment),
  SuggestedRule('apple.com/bill', Cat.subscriptions),
  SuggestedRule('github', Cat.subscriptions),
  SuggestedRule('openai', Cat.subscriptions),
  SuggestedRule('anthropic', Cat.subscriptions),
  // Entertainment
  SuggestedRule('steam', Cat.entertainment),
  SuggestedRule('playstation', Cat.entertainment),
  SuggestedRule('xbox', Cat.entertainment),
  SuggestedRule('fanduel', Cat.entertainment),
  // Medical & Healthcare
  SuggestedRule('cvs', Cat.medical),
  SuggestedRule('walgreens', Cat.medical),
  SuggestedRule('pharmacy', Cat.medical),
  // Personal
  SuggestedRule('amazon', Cat.personal),
  SuggestedRule('target', Cat.personal),
  SuggestedRule('walmart', Cat.personal),
  SuggestedRule('best buy', Cat.personal),
  // Family & Pets
  SuggestedRule('petco', Cat.family),
  SuggestedRule('petsmart', Cat.family),
];
