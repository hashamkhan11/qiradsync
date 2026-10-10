import 'dart:convert';

import 'package:qirad_core/qirad_core.dart';

import '../storage/record_store.dart';

/// The join code the investor shows (spec 2.1, step 3): the partnership id
/// and the investor's public key.
///
/// The code is not secret and not signed. Nothing here makes the join safe by
/// itself: the pin does. Every create is checked against the keys the phone
/// pinned, so a create signed by anyone else is refused (spec 2.1).
///
/// Wire format: base64url without padding, of this JSON object:
/// `{"v":1,"partnership":"...","investor":"..."}`. The format is an app choice;
/// the spec only fixes what the code carries.
class JoinCode {
  const JoinCode({required this.partnership, required this.investorKey});

  /// Bump this when the format changes, so an old app can refuse a new code.
  static const version = 1;

  final String partnership;
  final String investorKey;

  String encode() {
    final json = jsonEncode({
      'v': version,
      'partnership': partnership,
      'investor': investorKey,
    });
    return encodeBase64UrlNoPadding(utf8.encode(json));
  }

  /// Reads a join code. Throws [FormatException] for anything that is not a
  /// well-formed code, so a bad scan never pins a wrong key.
  static JoinCode parse(String text) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(decodeBase64UrlNoPadding(text)));
    } on FormatException {
      throw const FormatException('not a join code');
    }
    if (json is! Map<String, dynamic> || json['v'] != version) {
      throw const FormatException(
        'not a join code, or a version this app does not read',
      );
    }

    final partnership = json['partnership'];
    if (partnership is! String || partnership.isEmpty) {
      throw const FormatException('the join code has no partnership id');
    }
    final investor = json['investor'];
    if (investor is! String || !isCanonicalPublicKey(investor)) {
      throw const FormatException('the join code has no valid investor key');
    }
    return JoinCode(partnership: partnership, investorKey: investor);
  }
}

/// Joins the partnership named in [code] on this phone (spec 2.1, step 4).
///
/// The phone pins the investor from the code and its own key as the manager.
/// From then on only the create that names both is accepted. The store keeps
/// the pins with the partnership id.
Future<void> joinPartnership({
  required JoinCode code,
  required RecordStore store,
  required Ed25519KeyPair ownKeys,
}) async {
  final manager = ownKeys.publicKeyBase64Url;
  // Two partners have two different keys. A phone that holds the investor's
  // key is the investor, so it does not join its own partnership as manager.
  if (code.investorKey == manager) {
    throw ArgumentError.value(
      code.investorKey,
      'investorKey',
      'this phone holds the investor key; a partner cannot join as both',
    );
  }
  await store.addPartnership(
    code.partnership,
    investorKey: code.investorKey,
    managerKey: manager,
  );
}
