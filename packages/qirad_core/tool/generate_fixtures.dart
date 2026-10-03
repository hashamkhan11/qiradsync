// Writes testdata/dart_signed_records.json: records signed in Dart that the PHP
// relay must verify. Run from packages/qirad_core:
//
//   dart run tool/generate_fixtures.dart
//
// Never edit the JSON by hand. The keys below are TEST KEYS ONLY, derived from
// fixed labels so the output is the same on every run.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:qirad_core/qirad_core.dart';

import '../test/support/test_ids.dart';

const fixturePath = '../../testdata/dart_signed_records.json';

/// A key pair from a label. The seed is the private key, so only test code uses this.
Future<Ed25519KeyPair> testKey(String label) async {
  final seed = sha256.convert(utf8.encode('qiradsync test key: $label')).bytes;
  final pair = await Ed25519().newKeyPairFromSeed(seed);
  final publicKey = await pair.extractPublicKey();
  return Ed25519KeyPair(privateKeyBytes: seed, publicKeyBytes: publicKey.bytes);
}

/// Builds the fixture as pretty JSON. The same input always gives the same output.
Future<String> buildDartFixture() async {
  final investor = await testKey('investor');
  final manager = await testKey('manager');
  final investorKey = encodeBase64UrlNoPadding(investor.publicKeyBytes);
  final managerKey = encodeBase64UrlNoPadding(manager.publicKeyBytes);
  final partnership = testId('partnership-dart-fixture');
  final zeroHash = '0' * 64;

  final create = await signRecord(
    Record(
      v: 1,
      id: partnership,
      partnership: partnership,
      author: investorKey,
      seq: 1,
      prevHash: zeroHash,
      type: 'partnership_create',
      body: {
        'investor': investorKey,
        'manager': managerKey,
        'ratio': {'investor': 60, 'manager': 40},
        'currency': 'PKR',
      },
      refersTo: null,
      // Non-ASCII note: the relay must keep these bytes exactly.
      note: 'شراکت نامہ',
      time: '2026-10-03T10:00:00Z',
      sig: '',
    ),
    investor,
  );

  final invest = await signRecord(
    Record(
      v: 1,
      id: testId('dart-invest-2'),
      partnership: partnership,
      author: investorKey,
      seq: 2,
      prevHash: recordHash(create.toJson()),
      type: 'invest',
      body: {'amount': 150000},
      refersTo: null,
      note: 'سرمایہ کاری کی پہلی قسط',
      time: '2026-10-03T10:00:00Z',
      sig: '',
    ),
    investor,
  );

  // An empty body: `approve` takes no body fields (spec 5).
  final approve = await signRecord(
    Record(
      v: 1,
      id: testId('dart-approve-1'),
      partnership: partnership,
      author: managerKey,
      seq: 1,
      prevHash: zeroHash,
      type: 'approve',
      body: const {},
      refersTo: invest.id,
      note: '',
      time: '2026-10-03T10:00:00Z',
      sig: '',
    ),
    manager,
  );

  final records = [create, invest, approve];
  final output = {
    'records': [for (final r in records) canonicalJson(r.toJson())],
    'expected': [
      for (final r in records) {'id': r.id, 'hash': recordHash(r.toJson())},
    ],
  };
  return '${const JsonEncoder.withIndent('  ').convert(output)}\n';
}

const registrationPath = '../../testdata/registration_vector.json';

/// A device registration signed in Dart, for the relay to verify (spec 7.2).
/// The nonce is fixed here; a real relay issues random ones. The PHP test
/// stores this nonce itself, then posts the registration.
Future<String> buildRegistrationVector() async {
  final device = await testKey('device');
  final nonce = encodeBase64UrlNoPadding(
    sha256.convert(utf8.encode('qiradsync test nonce')).bytes,
  );
  final output = {
    'publicKey': device.publicKeyBase64Url,
    'nonce': nonce,
    'signature': await signRegistrationChallenge(device, nonce),
  };
  return '${const JsonEncoder.withIndent('  ').convert(output)}\n';
}

const relayVectorPath = '../../relay/tests/Fixtures/record_vector.json';

/// One signed record for the relay's own PHP tests (RecordSignatureTest and
/// RecordsStorageTest). The PHP side checks the signature and the stored bytes.
Future<String> buildRelayVector() async {
  final investor = await testKey('investor');
  final investorKey = encodeBase64UrlNoPadding(investor.publicKeyBytes);
  final partnership = testId('partnership-vector');
  final id = testId('vector-invest-1');
  final record = await signRecord(
    Record(
      v: 1,
      id: id,
      partnership: partnership,
      author: investorKey,
      seq: 1,
      prevHash: '0' * 64,
      type: 'invest',
      body: {'amount': 150000},
      refersTo: null,
      // Non-ASCII note: the relay must keep these bytes exactly.
      note: 'سرمایہ کاری کی پہلی قسط',
      time: '2026-10-02T10:00:00Z',
      sig: '',
    ),
    investor,
  );
  final canonical = canonicalJson(record.toJson());
  final output = {
    'canonical': canonical,
    'hash': recordHash(record.toJson()),
    'partnership': partnership,
    'author': investorKey,
    'seq': 1,
    'id': id,
    'publicKey': investorKey,
  };
  return '${const JsonEncoder.withIndent('  ').convert(output)}\n';
}

Future<void> main() async {
  await File(fixturePath).writeAsString(await buildDartFixture());
  stdout.writeln('wrote $fixturePath');
  await File(registrationPath).writeAsString(await buildRegistrationVector());
  stdout.writeln('wrote $registrationPath');
  await File(relayVectorPath).writeAsString(await buildRelayVector());
  stdout.writeln('wrote $relayVectorPath');
}
