import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/mcc.dart';

void main() {
  test('common merchant category codes map to plain categories', () {
    expect(categoryForMcc('5411'), 'Groceries');
    expect(categoryForMcc('5812'), 'Dining');
    expect(categoryForMcc('5814'), 'Dining');
    expect(categoryForMcc('5541'), 'Gas');
    expect(categoryForMcc('4121'), 'Transportation');
    expect(categoryForMcc('3010'), 'Travel');
    expect(categoryForMcc('4900'), 'Utilities');
    expect(categoryForMcc('8062'), 'Health');
    expect(categoryForMcc('7832'), 'Entertainment');
  });

  test('missing, blank or unknown codes give nothing', () {
    expect(categoryForMcc(null), isNull);
    expect(categoryForMcc(''), isNull);
    expect(categoryForMcc('abcd'), isNull);
    expect(categoryForMcc('0001'), isNull);
  });
}
