import 'package:mobile/storage/key_store.dart';

/// An in-memory stand-in for the platform store. It keeps values only for
/// the life of the test, and does not hide anything.
class FakeSecretStore implements SecretStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String name) async => values[name];

  @override
  Future<void> write(String name, String value) async => values[name] = value;
}
