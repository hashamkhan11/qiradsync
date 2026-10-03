import 'dart:convert';

import 'package:qirad_core/qirad_core.dart';

/// Builds signed record texts for tests, with fresh keys each time.
class SignedTexts {
  SignedTexts._(this.investor, this.manager);

  static Future<SignedTexts> create() async {
    return SignedTexts._(
      await generateEd25519KeyPair(),
      await generateEd25519KeyPair(),
    );
  }

  final Ed25519KeyPair investor;
  final Ed25519KeyPair manager;

  /// The partnership_create. Its id is the partnership id.
  Future<String> partnershipCreate({String partnership = 'p1'}) async {
    final unsigned = Record(
      v: 1,
      id: partnership,
      partnership: partnership,
      author: investor.publicKeyBase64Url,
      seq: 1,
      prevHash: '0' * 64,
      type: 'partnership_create',
      body: {
        'investor': investor.publicKeyBase64Url,
        'manager': manager.publicKeyBase64Url,
        'ratio': {'investor': 60, 'manager': 40},
        'currency': 'PKR',
      },
      refersTo: null,
      note: '',
      time: '2026-10-03T10:00:00Z',
      sig: '',
    );
    return canonicalJson((await signRecord(unsigned, investor)).toJson());
  }

  /// An investor record that follows [prevText] in the investor's chain.
  Future<String> invest({
    required String id,
    required int seq,
    required String prevText,
    String partnership = 'p1',
  }) async {
    final unsigned = Record(
      v: 1,
      id: id,
      partnership: partnership,
      author: investor.publicKeyBase64Url,
      seq: seq,
      prevHash: recordHash(jsonDecode(prevText) as Map<String, dynamic>),
      type: 'invest',
      body: {'amount': 150000},
      refersTo: null,
      note: '',
      time: '2026-10-03T10:00:00Z',
      sig: '',
    );
    return canonicalJson((await signRecord(unsigned, investor)).toJson());
  }

  /// A manager record at any seq, as used for equivocation.
  Future<String> approve({
    required String id,
    required int seq,
    String partnership = 'p1',
  }) async {
    final unsigned = Record(
      v: 1,
      id: id,
      partnership: partnership,
      author: manager.publicKeyBase64Url,
      seq: seq,
      prevHash: '0' * 64,
      type: 'approve',
      body: const {},
      refersTo: 'invest-2',
      note: '',
      time: '2026-10-03T10:00:00Z',
      sig: '',
    );
    return canonicalJson((await signRecord(unsigned, manager)).toJson());
  }
}
