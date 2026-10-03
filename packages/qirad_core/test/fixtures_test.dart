import 'dart:convert';
import 'dart:io';

import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import '../tool/generate_fixtures.dart';

void main() {
  group('testdata/dart_signed_records.json (Dart -> PHP)', () {
    test('is up to date: regenerating it gives the same content', () async {
      final onDisk = jsonDecode(await File(fixturePath).readAsString());
      final regenerated = jsonDecode(await buildDartFixture());

      expect(
        onDisk,
        regenerated,
        reason:
            'The fixture is stale. Run: dart run tool/generate_fixtures.dart',
      );
    });

    test('every record is accepted by the phone validator, in order', () async {
      final fixture =
          jsonDecode(await File(fixturePath).readAsString())
              as Map<String, dynamic>;
      final validator = Validator.unpinnedForTesting();

      for (final text in (fixture['records'] as List).cast<String>()) {
        expect(
          await validator.receiveText(text),
          ReceiveOutcome.accepted,
          reason: text,
        );
      }
    });
  });

  group('testdata/registration_vector.json (Dart -> PHP)', () {
    test('is up to date: regenerating it gives the same content', () async {
      final onDisk = jsonDecode(await File(registrationPath).readAsString());
      final regenerated = jsonDecode(await buildRegistrationVector());

      expect(
        onDisk,
        regenerated,
        reason:
            'The vector is stale. Run: dart run tool/generate_fixtures.dart',
      );
    });

    test(
      'the signature verifies with the public key and nonce in the file',
      () async {
        final vector =
            jsonDecode(await File(registrationPath).readAsString())
                as Map<String, dynamic>;

        expect(
          await verifyRegistrationChallenge(
            publicKey: vector['publicKey'] as String,
            nonce: vector['nonce'] as String,
            signature: vector['signature'] as String,
          ),
          isTrue,
        );
      },
    );
  });
}
