/// The categories Clearly starts with. Names are plain text everywhere else
/// (budget targets, rules and entries all just store the name), so this list
/// is the single place the built-in names live: the merchant-code table, the
/// statement-text matcher and the Categorize picker all read from it.
///
/// The person's own categories are always allowed alongside these.
class Cat {
  const Cat._();

  // ---- spending ----
  static const food = 'Food & Dining';
  static const groceries = 'Groceries';
  static const housing = 'Housing';
  static const utilities = 'Utilities & Bills';
  static const auto = 'Transportation';
  static const financial = 'Financial Services';
  static const medical = 'Medical & Healthcare';
  static const personal = 'Personal';
  static const entertainment = 'Entertainment';
  static const subscriptions = 'Subscriptions & Software';
  static const travel = 'Travel';
  static const education = 'Education';
  static const family = 'Family & Pets';
  static const gifts = 'Gifts & Donations';
  static const taxes = 'Taxes & Government';
  static const transfers = 'Transfers';
  static const other = 'Other';

  // ---- income ----
  static const paycheck = 'Paycheck';
  static const interest = 'Interest & Dividends';
  static const refunds = 'Refunds & Reimbursements';
  static const otherIncome = 'Other Income';
}

/// What each built-in category is for, shown when choosing one.
const Map<String, String> categoryHints = {
  Cat.food: 'Restaurants, coffee, fast food, delivery',
  Cat.groceries: 'Supermarkets and food shopping',
  Cat.housing: 'Rent, mortgage, HOA, home repair and furnishing',
  Cat.utilities: 'Electric, water, natural gas, internet, phone',
  Cat.auto:
      'Gas stations and fuel, rideshare, transit, parking, tolls, repairs',
  Cat.financial:
      'Insurance, bank and ATM fees, interest, loan and car payments',
  Cat.medical: 'Doctor, dentist, vision, pharmacy, urgent care, vet',
  Cat.personal: 'Shopping, clothing, salon, barber, gym',
  Cat.entertainment: 'Streaming, music, games, movies, events, tickets',
  Cat.subscriptions: 'Software, cloud, apps and other recurring services',
  Cat.travel: 'Flights, hotels, rentals, trips',
  Cat.education: 'Tuition, books, courses',
  Cat.family: 'Childcare, kids, pet food and supplies',
  Cat.gifts: 'Gifts and charity',
  Cat.taxes: 'Taxes, fines, government fees',
  Cat.transfers: 'Money you sent to people or to yourself',
};

/// Spending categories in the order they are offered.
const defaultSpendingCategories = <String>[
  Cat.food,
  Cat.groceries,
  Cat.housing,
  Cat.utilities,
  Cat.auto,
  Cat.financial,
  Cat.medical,
  Cat.personal,
  Cat.entertainment,
  Cat.subscriptions,
  Cat.travel,
  Cat.education,
  Cat.family,
  Cat.gifts,
  Cat.taxes,
  Cat.transfers,
  Cat.other,
];

/// Names earlier builds assigned automatically, and what they are now.
/// Applied once to bank entries only, so a category the person chose
/// themselves is never renamed.
const legacyCategoryNames = <String, String>{
  'Dining': Cat.food,
  'Gas': Cat.auto,
  'Auto': Cat.auto,
  'Auto & Transport': Cat.auto,
  'Utilities': Cat.utilities,
  'Insurance': Cat.financial,
  'Cash': Cat.financial,
  'Payments': Cat.financial,
  'Health': Cat.medical,
  'Personal care': Cat.personal,
  'Fitness': Cat.personal,
  'Shopping': Cat.personal,
  'Home': Cat.housing,
  'Subscriptions': Cat.subscriptions,
  'Taxes & fees': Cat.taxes,
  'Peer payments': Cat.transfers,
};
