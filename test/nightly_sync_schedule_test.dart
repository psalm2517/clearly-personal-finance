import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/screens/shell.dart';

void main() {
  test('before 1:30 AM the next sync is this morning', () {
    expect(nextNightlySyncTime(DateTime(2026, 10, 12, 0, 5)),
        DateTime(2026, 10, 12, 1, 30));
  });

  test('after 1:30 AM it is tomorrow morning, including at exactly 1:30', () {
    expect(nextNightlySyncTime(DateTime(2026, 10, 12, 9, 0)),
        DateTime(2026, 10, 13, 1, 30));
    expect(nextNightlySyncTime(DateTime(2026, 10, 12, 1, 30)),
        DateTime(2026, 10, 13, 1, 30));
  });

  test('it rolls over month and year ends', () {
    expect(nextNightlySyncTime(DateTime(2026, 12, 31, 23, 59)),
        DateTime(2027, 1, 1, 1, 30));
    expect(nextNightlySyncTime(DateTime(2026, 2, 28, 12)),
        DateTime(2026, 3, 1, 1, 30));
  });
}
