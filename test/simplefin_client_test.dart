import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:clearly/data/simplefin.dart';

class FakeTransport implements SimpleFinTransport {
  FakeTransport(this.respond);
  final ({int status, String body}) Function(String method, Uri url,
      Map<String, String> headers) respond;
  final calls = <(String, Uri, Map<String, String>)>[];

  @override
  Future<({int status, String body})> send(String method, Uri url,
      {Map<String, String> headers = const {}}) async {
    calls.add((method, url, headers));
    return respond(method, url, headers);
  }
}

String token(String url) => base64.encode(utf8.encode(url));

void main() {
  group('setup token', () {
    test('decodes padded, unpadded and url-safe forms, ignoring whitespace',
        () {
      const url = 'https://beta-bridge.simplefin.org/simplefin/claim/DEMO-1';
      final padded = token(url);
      expect(SimpleFinClient.claimUrlFromToken(padded).toString(), url);
      expect(
          SimpleFinClient.claimUrlFromToken(padded.replaceAll('=', ''))
              .toString(),
          url);
      expect(SimpleFinClient.claimUrlFromToken(' ${padded}\n').toString(), url);
      expect(
          SimpleFinClient.claimUrlFromToken(
                  padded.replaceAll('+', '-').replaceAll('/', '_'))
              .toString(),
          url);
    });

    test('rejects junk and non-https tokens with a readable message', () {
      expect(() => SimpleFinClient.claimUrlFromToken(''),
          throwsA(isA<SimpleFinException>()));
      expect(() => SimpleFinClient.claimUrlFromToken('not base64 !!'),
          throwsA(isA<SimpleFinException>()));
      expect(
          () => SimpleFinClient.claimUrlFromToken(
              token('http://bridge.example/claim/1')),
          throwsA(isA<SimpleFinException>()));
    });
  });

  group('claim', () {
    test('POSTs to the url inside the token and returns the access url',
        () async {
      final t = FakeTransport((m, u, h) =>
          (status: 200, body: 'https://user:pass@bridge.example/simplefin\n'));
      final access = await SimpleFinClient(transport: t)
          .claim(token('https://bridge.example/simplefin/claim/ABC'));
      expect(access, 'https://user:pass@bridge.example/simplefin');
      expect(t.calls.single.$1, 'POST');
      expect(t.calls.single.$2.path, '/simplefin/claim/ABC');
    });

    test('a used token (403) says so', () async {
      final t = FakeTransport((m, u, h) => (status: 403, body: ''));
      expect(
          () => SimpleFinClient(transport: t)
              .claim(token('https://bridge.example/c/1')),
          throwsA(isA<SimpleFinException>()
              .having((e) => e.message, 'message', contains('already'))));
    });

    test('refuses a response that is not an access url', () async {
      final t = FakeTransport((m, u, h) => (status: 200, body: '<html>'));
      expect(
          () => SimpleFinClient(transport: t)
              .claim(token('https://bridge.example/c/1')),
          throwsA(isA<SimpleFinException>()));
    });
  });

  group('fetch', () {
    test('sends basic auth from the url, version 2, dates and flags', () async {
      final t = FakeTransport(
          (m, u, h) => (status: 200, body: '{"errlist":[],"accounts":[]}'));
      await SimpleFinClient(transport: t).fetch(
        'https://user:pa%40ss@bridge.example/simplefin',
        start: DateTime.utc(2026, 1, 1),
        end: DateTime.utc(2026, 2, 1),
        pending: true,
        balancesOnly: true,
      );
      final (method, url, headers) = t.calls.single;
      expect(method, 'GET');
      expect(url.host, 'bridge.example');
      expect(url.userInfo, isEmpty, reason: 'credentials go in the header');
      expect(url.path, '/simplefin/accounts');
      expect(url.queryParameters['version'], '2');
      expect(url.queryParameters['start-date'], '1767225600');
      expect(url.queryParameters['end-date'], '1769904000');
      expect(url.queryParameters['pending'], '1');
      expect(url.queryParameters['balances-only'], '1');
      expect(headers['authorization'],
          'Basic ${base64.encode(utf8.encode('user:pa@ss'))}');
    });

    test('402 and 403 give actionable messages', () async {
      for (final (status, word) in [(402, 'subscription'), (403, 'connect')]) {
        final t = FakeTransport((m, u, h) => (status: status, body: ''));
        expect(
            () => SimpleFinClient(transport: t)
                .fetch('https://u:p@bridge.example/simplefin'),
            throwsA(isA<SimpleFinException>()
                .having((e) => e.message, 'message', contains(word))));
      }
    });
  });

  group('parsing', () {
    const body = '''
{
  "errlist": [{"code": "gen.auth", "msg": "Sign in again at Example Bank",
               "conn_id": "c1"}],
  "accounts": [
    {"id": "A1", "name": "Everyday", "currency": "USD",
     "balance": "1234.56", "balance-date": 1767312000,
     "org": {"name": "Example Bank", "domain": "example.com"},
     "transactions": [
       {"id": "t1", "posted": 1767312000, "amount": "-12.34",
        "description": " COFFEE  "},
       {"id": "t2", "posted": 0, "amount": "100", "description": "Pending",
        "pending": true},
       {"id": "bad", "posted": 1767312000, "amount": "abc"}
     ]},
    {"id": "C1", "name": "Card", "balance": "-250.00", "transactions": []}
  ]
}''';

    test('maps accounts, org, balances and transactions', () {
      final data = SimpleFinClient.parseResponse(body);
      expect(data.accounts, hasLength(2));
      final a = data.accounts.first;
      expect(a.id, 'A1');
      expect(a.orgName, 'Example Bank');
      expect(a.balanceCents, 123456);
      expect(a.balanceDate, isNotNull);
      expect(a.transactions, hasLength(2), reason: 'unparseable amount skipped');
      expect(a.transactions.first.amountCents, -1234);
      expect(a.transactions.first.description, 'COFFEE');
      expect(a.transactions[1].pending, isTrue);
      expect(data.accounts[1].balanceCents, -25000);
      expect(data.accounts[1].orgName, isNull);
    });

    test('keeps the structured errors so they can be shown', () {
      final data = SimpleFinClient.parseResponse(body);
      expect(data.errors.single.code, 'gen.auth');
      expect(data.errors.single.needsAttention, isTrue);
      expect(data.errors.single.message, contains('Example Bank'));
    });

    test('rejects a response that is not json', () {
      expect(() => SimpleFinClient.parseResponse('<html>'),
          throwsA(isA<SimpleFinException>()));
    });
  });

  test('parseDecimalCents is exact', () {
    expect(parseDecimalCents('1234.56'), 123456);
    expect(parseDecimalCents('-0.07'), -7);
    expect(parseDecimalCents('12'), 1200);
    expect(parseDecimalCents('+5.5'), 550);
    expect(parseDecimalCents('0.1'), 10);
    expect(parseDecimalCents('19.999'), 2000);
    expect(parseDecimalCents('1e3'), isNull);
    expect(parseDecimalCents(''), isNull);
    expect(parseDecimalCents('12.3.4'), isNull);
  });
}
