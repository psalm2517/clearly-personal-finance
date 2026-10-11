import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/merchants.dart';

void main() {
  test('common statement lines get a plain category', () {
    final cases = {
      'UBER   *EATS': 'Food & Dining',
      'AplPay UBER EATS help.uber.com CA': 'Food & Dining',
      "DOMINO'S": 'Food & Dining',
      'CHIPOTLE MEX GR ONLINE': 'Food & Dining',
      'SUBWAY': 'Food & Dining',
      'UBER   *TRIP': 'Transportation',
      'MTA*NYCT PAYGO': 'Transportation',
      'BP GREAT WASH': 'Transportation',
      'GEICO  *AUTO': 'Financial Services',
      'AGI*RENTERS/CONDO INS': 'Financial Services',
      'SPOTIFY USA NEW YORK NY': 'Subscriptions & Software',
      'ANTHROPIC* CLAUDE SUSAN FRANCISCO CA': 'Subscriptions & Software',
      'METRO BY T-MOBILE AUTO': 'Utilities & Bills',
      'WL *STEAM PURCHASE': 'Entertainment',
      'FOOD UNIVERSE #': 'Groceries',
      'Zelle payment to ANDREA': 'Transfers',
      'Online Transfer to CHK ...': 'Transfers',
      'WF PAYMENT': 'Financial Services',
    };
    cases.forEach((text, want) {
      expect(categoryForDescription(text), want, reason: text);
    });
  });

  test('unrecognised lines are left for the person', () {
    expect(categoryForDescription('SQ *ALMOSTAFA LLC'), isNull);
    expect(categoryForDescription(''), isNull);
    expect(categoryForDescription(null), isNull);
  });

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
}
