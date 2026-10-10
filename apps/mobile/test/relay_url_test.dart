import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/sync/relay_url.dart';

void main() {
  group('validateRelayUrl (spec 7.2)', () {
    test('an empty URL is refused', () {
      expect(
        () => validateRelayUrl('', debug: true),
        throwsA(isA<RelayUrlError>()),
      );
    });

    test('a malformed URL is refused', () {
      expect(
        () => validateRelayUrl('not a url', debug: true),
        throwsA(isA<RelayUrlError>()),
      );
    });

    test('https to a remote host is always allowed', () {
      final uri = validateRelayUrl('https://relay.example.com', debug: false);
      expect(uri.host, 'relay.example.com');
    });

    test('http to a remote host is refused in debug', () {
      expect(
        () => validateRelayUrl('http://relay.example.com', debug: true),
        throwsA(isA<RelayUrlError>()),
      );
    });

    test('http to a remote host is refused in release', () {
      expect(
        () => validateRelayUrl('http://relay.example.com', debug: false),
        throwsA(isA<RelayUrlError>()),
      );
    });

    test('http to the Android emulator host is allowed in debug', () {
      final uri = validateRelayUrl('http://10.0.2.2:8000', debug: true);
      expect(uri.host, '10.0.2.2');
    });

    test('http to localhost is refused in release', () {
      expect(
        () => validateRelayUrl('http://localhost:8000', debug: false),
        throwsA(isA<RelayUrlError>()),
      );
    });
  });
}
