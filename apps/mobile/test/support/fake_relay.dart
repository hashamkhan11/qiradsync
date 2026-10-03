import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qirad_core/qirad_core.dart';

/// A stand-in for the relay, for sync tests.
///
/// It does NOT check signatures. The real relay does that and has its own
/// tests. This fake does the parts the sync client depends on: it keeps
/// exact texts, keeps every version at a position, computes a gap-aware
/// vector (spec 7.1), and returns records after the client's vector.
class FakeRelay {
  /// Texts by position, in arrival order. Key: `author|seq`.
  final Map<String, List<String>> _positions = {};
  final Set<String> _hashes = {};

  /// Ids the relay loses on their first upload (a gap on the relay).
  final Set<String> dropOnce = {};

  /// When true, the relay accepts uploads but stores nothing.
  bool dropAll = false;

  /// When set, every call is refused with this status.
  int? refuseWith;

  int calls = 0;
  String? lastAuthorization;

  late final http.Client client = MockClient(_handle);

  int get storedCount => _positions.values.fold(0, (n, v) => n + v.length);

  /// Puts a text on the relay as if another device had uploaded it.
  void seed(String text) => _store(text);

  void _store(String text) {
    final json = jsonDecode(text) as Map<String, dynamic>;
    if (!_hashes.add(recordHash(json))) return;
    final key = '${json['author']}|${json['seq']}';
    _positions.putIfAbsent(key, () => []).add(text);
  }

  Future<http.Response> _handle(http.Request request) async {
    calls++;
    lastAuthorization = request.headers['Authorization'];
    if (refuseWith != null) return http.Response('', refuseWith!);

    final body = jsonDecode(request.body) as Map<String, dynamic>;
    for (final text in (body['records'] as List).cast<String>()) {
      final json = jsonDecode(text) as Map<String, dynamic>;
      if (dropAll) continue;
      if (dropOnce.remove(json['id'])) continue;
      _store(text);
    }

    final clientVector = (body['vector'] as Map<String, dynamic>)
        .cast<String, int>();
    final records = <String>[];
    final conflicts = <String>[];
    for (final key in _sortedKeys()) {
      final versions = _positions[key]!;
      final author = key.split('|').first;
      final seq = int.parse(key.split('|').last);
      if (seq > (clientVector[author] ?? 0)) records.add(versions.first);
      if (versions.length > 1) conflicts.addAll(versions);
    }

    return http.Response(
      jsonEncode({
        'accepted': <String>[],
        'already': <String>[],
        'rejected': <Object>[],
        'conflicts': conflicts,
        'records': records,
        'vector': _vector(),
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  /// Keys sorted by author, then by seq as a number (not as text).
  List<String> _sortedKeys() {
    final keys = _positions.keys.toList()
      ..sort((a, b) {
        final authorA = a.split('|').first;
        final authorB = b.split('|').first;
        if (authorA != authorB) return authorA.compareTo(authorB);
        return int.parse(
          a.split('|').last,
        ).compareTo(int.parse(b.split('|').last));
      });
    return keys;
  }

  /// Gap-aware, as in spec 7.1: highest seq reached without a missing one.
  Map<String, int> _vector() {
    final seqsByAuthor = <String, Set<int>>{};
    for (final key in _positions.keys) {
      final author = key.split('|').first;
      final seq = int.parse(key.split('|').last);
      seqsByAuthor.putIfAbsent(author, () => {}).add(seq);
    }
    final vector = <String, int>{};
    seqsByAuthor.forEach((author, seqs) {
      var top = 0;
      while (seqs.contains(top + 1)) {
        top++;
      }
      if (top > 0) vector[author] = top;
    });
    return vector;
  }
}
