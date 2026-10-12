import 'package:qirad_core/qirad_core.dart';

/// One simulated phone: its own signing key and the [Validator] it has run
/// every record it has seen through. The generator makes one investor and
/// one manager [Device]; each only ever signs with its own key, and its
/// validator only ever learns about a record once that record is "delivered"
/// to it — instantly for its own records, after a modeled delay for the
/// other partner's (see `workload_generator.dart`).
class Device {
  Device({required this.keyPair, required this.validator});

  final Ed25519KeyPair keyPair;
  final Validator validator;

  /// The `author` field value this device signs with.
  String get key => keyPair.publicKeyBase64Url;
}
