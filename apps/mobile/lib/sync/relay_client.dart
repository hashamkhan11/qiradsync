import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

/// What the relay sends back from one `sync` call (spec 7.2).
class SyncReply {
  const SyncReply({
    required this.records,
    required this.conflicts,
    required this.vector,
  });

  /// Canonical record texts this partnership has that the phone asked for.
  final List<String> records;

  /// Every version held at each position where two versions conflict.
  final List<String> conflicts;

  /// The relay's own vector, computed live (spec 7.2). The repair step
  /// compares this, never a remembered value.
  final Map<String, int> vector;
}

/// The relay answered with a status other than 200 or 201. The body is not kept.
class RelayRefused implements Exception {
  RelayRefused(this.status);

  final int status;

  @override
  String toString() => 'the relay refused the sync with HTTP $status';
}

/// Talks to the relay's sync endpoint. It sends and receives exact texts and
/// makes no decisions about them. The validator decides, later.
class RelayClient {
  RelayClient({
    required this.baseUrl,
    required this.httpClient,
    this.requestTimeout = const Duration(seconds: 30),
  });

  /// The client the phone uses. A relay that is down or silent must not hang
  /// the app. The connection must open within 10 seconds, and the whole call
  /// must finish within [requestTimeout]. A timeout is a [TimeoutException],
  /// which the sync runner retries with backoff (spec 7.3, step 6).
  factory RelayClient.live({
    required String baseUrl,
    Duration requestTimeout = const Duration(seconds: 30),
  }) {
    final inner = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    return RelayClient(
      baseUrl: baseUrl,
      httpClient: IOClient(inner),
      requestTimeout: requestTimeout,
    );
  }

  /// For example `https://relay.example.com`, without a trailing slash.
  final String baseUrl;

  /// Injected so tests can replace the network with a fake.
  final http.Client httpClient;

  /// The longest a single call may take, from sending to the full answer.
  final Duration requestTimeout;

  /// `POST /api/v1/devices/challenge` (spec 7.2, step 1). Returns the nonce
  /// the relay issued for this key. The nonce is single use.
  Future<String> requestChallenge({required String publicKey}) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/api/v1/devices/challenge'),
          headers: _jsonHeaders,
          body: jsonEncode({'publicKey': publicKey}),
        )
        .timeout(requestTimeout);
    if (response.statusCode != 201) throw RelayRefused(response.statusCode);

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return json['nonce'] as String;
  }

  /// `POST /api/v1/devices` (spec 7.2, step 2). The signature proves this
  /// phone holds the key. Returns the bearer token for later syncs.
  Future<String> register({
    required String publicKey,
    required String nonce,
    required String signature,
  }) async {
    final response = await httpClient
        .post(
          Uri.parse('$baseUrl/api/v1/devices'),
          headers: _jsonHeaders,
          body: jsonEncode({
            'publicKey': publicKey,
            'nonce': nonce,
            'signature': signature,
          }),
        )
        .timeout(requestTimeout);
    if (response.statusCode != 201) throw RelayRefused(response.statusCode);

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return json['token'] as String;
  }

  static const _jsonHeaders = {
    'Accept': 'application/json',
    'Content-Type': 'application/json',
  };

  /// One call to `POST /api/v1/partnerships/{id}/sync`.
  ///
  /// [records] are sent as their exact texts. JSON encodes a string without
  /// changing its characters, so the relay receives the same bytes the phone
  /// holds. Network errors and timeouts are not caught here: retry is the
  /// sync runner's job.
  Future<SyncReply> sync({
    required String partnership,
    required String token,
    required Map<String, int> vector,
    required List<String> records,
  }) async {
    final url = Uri.parse(
      '$baseUrl/api/v1/partnerships/${Uri.encodeComponent(partnership)}/sync',
    );
    final response = await httpClient
        .post(
          url,
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'vector': vector, 'records': records}),
        )
        .timeout(requestTimeout);
    if (response.statusCode != 200) throw RelayRefused(response.statusCode);

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return SyncReply(
      records: [for (final text in json['records'] as List) text as String],
      conflicts: [for (final text in json['conflicts'] as List) text as String],
      vector: {
        for (final entry in (json['vector'] as Map<String, dynamic>).entries)
          entry.key: entry.value as int,
      },
    );
  }
}
