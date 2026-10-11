import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A SimpleFIN Bridge client: claim a setup token, then read accounts and
/// transactions. See https://www.simplefin.org/protocol.html
///
/// The Bridge is a read-only feed. The Access URL it hands back contains
/// basic-auth credentials for *that feed only*; it never contains, and Clearly
/// never sees, the bank login.

/// Something went wrong talking to the Bridge, with a message that is safe to
/// show to the person using the app.
class SimpleFinException implements Exception {
  SimpleFinException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One entry of the response's `errlist`. The spec says to always show these.
class SimpleFinError {
  const SimpleFinError({required this.code, required this.message});
  final String code;
  final String message;

  /// The Bridge or the bank wants the person to act (re-authenticate, etc).
  bool get needsAttention =>
      code.startsWith('gen.auth') || code.contains('auth');

  @override
  String toString() => message.isEmpty ? code : message;
}

class SimpleFinTransaction {
  const SimpleFinTransaction({
    required this.id,
    required this.posted,
    required this.amountCents,
    required this.description,
    required this.pending,
    this.payee,
    this.memo,
    this.mcc,
  });

  /// Unique within its account, not across accounts.
  final String id;

  /// The calendar day it posted, in local time.
  final DateTime posted;

  /// Negative is money out of the account.
  final int amountCents;
  final String description;
  final bool pending;

  /// The clean merchant name, when the bank provides one. Often missing.
  final String? payee;

  /// The bank's raw statement text, when it differs from [description].
  final String? memo;

  /// Merchant category code, when the bank passes it along.
  final String? mcc;
}

class SimpleFinAccount {
  const SimpleFinAccount({
    required this.id,
    required this.name,
    required this.orgName,
    required this.currency,
    required this.balanceCents,
    required this.balanceDate,
    required this.transactions,
  });

  final String id;
  final String name;
  final String? orgName;
  final String currency;

  /// As the feed reports it: liabilities are normally negative.
  final int balanceCents;
  final DateTime? balanceDate;
  final List<SimpleFinTransaction> transactions;
}

class SimpleFinData {
  const SimpleFinData({required this.accounts, required this.errors});
  final List<SimpleFinAccount> accounts;
  final List<SimpleFinError> errors;
}

/// The HTTP layer, so tests can stand in for the network.
abstract class SimpleFinTransport {
  Future<({int status, String body})> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
  });
}

class HttpSimpleFinTransport implements SimpleFinTransport {
  HttpSimpleFinTransport({this.timeout = const Duration(seconds: 45)});
  final Duration timeout;

  @override
  Future<({int status, String body})> send(
    String method,
    Uri url, {
    Map<String, String> headers = const {},
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.openUrl(method, url).timeout(timeout);
      headers.forEach(request.headers.set);
      // The claim POST has no body, and the Bridge wants that stated.
      if (method == 'POST') request.contentLength = 0;
      final response = await request.close().timeout(timeout);
      final body = await response.transform(utf8.decoder).join();
      return (status: response.statusCode, body: body);
    } on TimeoutException {
      throw SimpleFinException(
        'The SimpleFIN Bridge took too long to answer. Try again shortly.',
      );
    } on SocketException {
      throw SimpleFinException(
        'Could not reach the SimpleFIN Bridge. Check your connection.',
      );
    } on HandshakeException {
      throw SimpleFinException(
        'Could not make a secure connection to the SimpleFIN Bridge.',
      );
    } finally {
      client.close(force: true);
    }
  }
}

class SimpleFinClient {
  SimpleFinClient({SimpleFinTransport? transport})
    : _transport = transport ?? HttpSimpleFinTransport();

  final SimpleFinTransport _transport;

  /// A setup token is the claim URL, base64 encoded. Accepts URL-safe and
  /// padded or unpadded forms, and stray whitespace from pasting.
  static Uri claimUrlFromToken(String token) {
    final cleaned = token.replaceAll(RegExp(r'\s'), '');
    if (cleaned.isEmpty) {
      throw SimpleFinException('Paste the setup token from SimpleFIN.');
    }
    String decoded;
    try {
      decoded = utf8.decode(base64.decode(base64.normalize(cleaned)));
    } on FormatException {
      throw SimpleFinException(
        'That does not look like a SimpleFIN setup token.',
      );
    }
    final uri = Uri.tryParse(decoded.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
      throw SimpleFinException(
        'That does not look like a SimpleFIN setup token.',
      );
    }
    return uri;
  }

  /// Exchanges a setup token for an Access URL. A setup token works once.
  Future<String> claim(String setupToken) async {
    final url = claimUrlFromToken(setupToken);
    final res = await _transport.send('POST', url);
    if (res.status == 403) {
      throw SimpleFinException(
        'SimpleFIN rejected that token. It may already have been used, '
        'so generate a new one.',
      );
    }
    if (res.status != 200) {
      throw SimpleFinException(
        'SimpleFIN could not claim that token (HTTP ${res.status}).',
      );
    }
    final access = res.body.trim();
    final parsed = Uri.tryParse(access);
    if (parsed == null || parsed.scheme != 'https' || parsed.userInfo.isEmpty) {
      throw SimpleFinException(
        'SimpleFIN returned something unexpected instead of an access URL.',
      );
    }
    return access;
  }

  /// Reads accounts, and their transactions in [start]..[end] (at most 90
  /// days apart, per the Bridge). With [balancesOnly] no transactions are
  /// returned, which is cheaper and is what linking accounts needs.
  Future<SimpleFinData> fetch(
    String accessUrl, {
    DateTime? start,
    DateTime? end,
    bool pending = false,
    bool balancesOnly = false,
  }) async {
    final access = Uri.parse(accessUrl);
    final creds = access.userInfo;
    final query = <String, String>{
      'version': '2',
      if (start != null)
        'start-date': '${start.toUtc().millisecondsSinceEpoch ~/ 1000}',
      if (end != null)
        'end-date': '${end.toUtc().millisecondsSinceEpoch ~/ 1000}',
      if (pending) 'pending': '1',
      if (balancesOnly) 'balances-only': '1',
    };
    final url = Uri(
      scheme: access.scheme,
      host: access.host,
      port: access.hasPort ? access.port : null,
      path: '${access.path.replaceAll(RegExp(r'/+$'), '')}/accounts',
      queryParameters: query,
    );
    final res = await _transport.send(
      'GET',
      url,
      headers: {
        HttpHeaders.authorizationHeader:
            'Basic ${base64.encode(utf8.encode(Uri.decodeComponent(creds)))}',
      },
    );
    if (res.status == 402) {
      throw SimpleFinException(
        'Your SimpleFIN subscription needs attention (payment required).',
      );
    }
    if (res.status == 403) {
      throw SimpleFinException(
        'SimpleFIN no longer accepts this connection. It may have been '
        'disabled, so connect again with a new token.',
      );
    }
    if (res.status != 200) {
      throw SimpleFinException(
        'SimpleFIN returned an error (HTTP ${res.status}).',
      );
    }
    return parseResponse(res.body);
  }

  /// Public for tests.
  static SimpleFinData parseResponse(String body) {
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw SimpleFinException(
        'SimpleFIN sent a response Clearly could not read.',
      );
    }
    if (json is! Map<String, dynamic>) {
      throw SimpleFinException(
        'SimpleFIN sent a response Clearly could not read.',
      );
    }
    final errors = <SimpleFinError>[];
    final rawErrors = json['errlist'];
    if (rawErrors is List) {
      for (final e in rawErrors) {
        if (e is Map) {
          errors.add(
            SimpleFinError(
              code: '${e['code'] ?? ''}',
              message: '${e['msg'] ?? ''}',
            ),
          );
        }
      }
    }
    // v1 servers sent plain strings in "errors".
    final legacy = json['errors'];
    if (legacy is List) {
      for (final e in legacy) {
        if (e is String) errors.add(SimpleFinError(code: '', message: e));
      }
    }
    // v2 describes each institution once in "connections", and accounts
    // point at it by conn_id.
    final connectionNames = <String, String>{};
    final rawConnections = json['connections'];
    if (rawConnections is List) {
      for (final c in rawConnections) {
        if (c is Map && c['conn_id'] != null) {
          final name = _text(c['org_name']) ?? _text(c['name']);
          if (name != null) connectionNames['${c['conn_id']}'] = name;
        }
      }
    }
    final accounts = <SimpleFinAccount>[];
    final rawAccounts = json['accounts'];
    if (rawAccounts is List) {
      for (final a in rawAccounts) {
        if (a is! Map) continue;
        final id = a['id'];
        if (id == null) continue;
        final txns = <SimpleFinTransaction>[];
        final rawTxns = a['transactions'];
        if (rawTxns is List) {
          for (final t in rawTxns) {
            if (t is! Map || t['id'] == null) continue;
            final cents = parseDecimalCents('${t['amount']}');
            if (cents == null) continue;
            final pending = t['pending'] == true;
            final epoch = _epoch(t['posted']) ?? _epoch(t['transacted_at']);
            final when = epoch == null || epoch == 0
                ? DateTime.now()
                : DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
            txns.add(
              SimpleFinTransaction(
                id: '${t['id']}',
                posted: DateTime(when.year, when.month, when.day),
                amountCents: cents,
                description: '${t['description'] ?? ''}'.trim(),
                pending: pending,
                payee: _text(t['payee']),
                memo: _text(t['memo']),
                mcc: _text(t['mcc']),
              ),
            );
          }
        }
        final org = a['org'];
        final balanceEpoch = _epoch(a['balance-date']);
        accounts.add(
          SimpleFinAccount(
            id: '$id',
            name: '${a['name'] ?? 'Account'}',
            orgName:
                connectionNames['${a['conn_id']}'] ??
                (org is Map
                    ? (org['name'] ?? org['domain'])?.toString()
                    : null),
            currency: '${a['currency'] ?? 'USD'}',
            balanceCents: parseDecimalCents('${a['balance']}') ?? 0,
            balanceDate: balanceEpoch == null || balanceEpoch == 0
                ? null
                : DateTime.fromMillisecondsSinceEpoch(balanceEpoch * 1000),
            transactions: txns,
          ),
        );
      }
    }
    return SimpleFinData(accounts: accounts, errors: errors);
  }

  static String? _text(Object? v) {
    final t = v?.toString().trim();
    return t == null || t.isEmpty ? null : t;
  }

  static int? _epoch(Object? v) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }
}

/// "-1234.56" to -123456 without going through a double, so amounts never
/// pick up float error. Returns null for anything that is not a plain decimal.
int? parseDecimalCents(String input) {
  final m = RegExp(r'^\s*([+-])?(\d+)(?:\.(\d+))?\s*$').firstMatch(input);
  if (m == null) return null;
  final whole = int.parse(m.group(2)!);
  var frac = m.group(3) ?? '';
  // Round half away from zero on anything past two places.
  final extra = frac.length > 2 && int.parse(frac[2]) >= 5 ? 1 : 0;
  frac = frac.padRight(2, '0').substring(0, 2);
  final cents = whole * 100 + int.parse(frac) + extra;
  return m.group(1) == '-' ? -cents : cents;
}
