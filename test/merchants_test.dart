import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/categories.dart';
import 'package:clearly/data/merchants.dart';

void main() {
  test('brokerage trades are recognised as activity, not spending', () {
    for (final t in [
      'YOU BOUGHT VOYAGER TECHNOLOGIES INC COM',
      'PURCHASE INTO CORE ACCOUNT FIDELITY GOVERNMENT MONEY MARKET',
      'REINVESTMENT FIDELITY GOVERNMENT MONEY MARKET',
    ]) {
      expect(brokerageActivity.hasMatch(t), isTrue, reason: t);
    }
    expect(brokerageActivity.hasMatch('Hulu'), isFalse);
  });

  test('suggestions are only offered, use built-in categories, and are '
      'unique', () {
    final keywords = suggestedRules.map((r) => r.keyword).toList();
    expect(keywords.toSet().length, keywords.length);
    for (final r in suggestedRules) {
      expect(defaultSpendingCategories, contains(r.category), reason: r.keyword);
      expect(r.keyword, r.keyword.toLowerCase());
    }
    expect(
        suggestedRules.any((r) => r.keyword == 'fanduel'), isTrue);
  });

  test('categories are listed alphabetically, Other last, then your own', () {
    final o = orderedCategories(['Zebra', 'apple', 'Food & Dining', 'Split']);
    expect(o.builtIn.first, 'Education');
    expect(o.builtIn.last, 'Other');
    expect(o.builtIn, containsAll(['Food & Dining', 'Transportation']));
    final names = o.builtIn.where((c) => c != 'Other').toList();
    expect([...names]..sort(), names);
    expect(o.yours, ['apple', 'Zebra'], reason: 'case-insensitive, no Split');
  });

  test('each built-in category has a hint, and the three easily confused '
      'ones say what belongs', () {
    for (final c in defaultSpendingCategories.where((c) => c != Cat.other)) {
      expect(categoryHints[c], isNotNull, reason: c);
    }
    expect(categoryHints[Cat.entertainment], contains('Steam'));
    expect(categoryHints[Cat.subscriptions], contains('Spotify'));
    expect(categoryHints[Cat.subscriptions], contains('cloud'));
    expect(categoryHints[Cat.personal], contains('salon'));
  });
}
