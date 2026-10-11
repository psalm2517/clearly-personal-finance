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
}
