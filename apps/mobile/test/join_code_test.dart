import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/join/join_code.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'support/signed_texts.dart';

/// The base64url alphabet, in order (RFC 4648 section 5).
const _alphabet =
    'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

/// A join code built by hand, so tests can put bad values in it.
String _rawCode(String partnership, String investor, {int version = 1}) {
  final json = jsonEncode({
    'v': version,
    'partnership': partnership,
    'investor': investor,
  });
  return encodeBase64UrlNoPadding(utf8.encode(json));
}

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late SignedTexts texts;
  late RecordStore store;
  late String investorKey;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qirad_join_test');
    texts = await SignedTexts.create();
    investorKey = texts.investor.publicKeyBase64Url;
    store = await RecordStore.open(
      factory: databaseFactoryFfi,
      path: p.join(dir.path, 'records.db'),
    );
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  group('JoinCode', () {
    test('encodes, then parses back to the same partnership and key', () {
      final parsed = JoinCode.parse(
        JoinCode(partnership: 'p1', investorKey: investorKey).encode(),
      );

      expect(parsed.partnership, 'p1');
      expect(parsed.investorKey, investorKey);
    });

    test('refuses text that is not base64url', () {
      expect(() => JoinCode.parse('not a code!'), throwsFormatException);
    });

    test('refuses valid base64 that is not JSON', () {
      final text = encodeBase64UrlNoPadding(utf8.encode('hello'));

      expect(() => JoinCode.parse(text), throwsFormatException);
    });

    test('refuses another version', () {
      expect(
        () => JoinCode.parse(_rawCode('p1', investorKey, version: 2)),
        throwsFormatException,
      );
    });

    test('refuses an empty partnership id', () {
      expect(
        () => JoinCode.parse(_rawCode('', investorKey)),
        throwsFormatException,
      );
    });

    test('refuses a key that is too short or too long', () {
      expect(
        () => JoinCode.parse(_rawCode('p1', investorKey.substring(0, 42))),
        throwsFormatException,
      );
      expect(
        () => JoinCode.parse(_rawCode('p1', '${investorKey}A')),
        throwsFormatException,
      );
    });

    test('refuses a second spelling of the same key', () {
      // The last character of a 43-character key holds 2 unused bits. Flipping
      // the lowest bit of that character changes only those unused bits, so the
      // text is a different spelling. The pin compares text, so such a code
      // must be refused, not quietly accepted.
      final last = _alphabet.indexOf(investorKey[42]);
      final otherSpelling = investorKey.substring(0, 42) + _alphabet[last ^ 1];
      expect(otherSpelling, isNot(investorKey));

      expect(
        () => JoinCode.parse(_rawCode('p1', otherSpelling)),
        throwsFormatException,
      );
    });
  });

  group('joinPartnership', () {
    test('pins the investor from the code and this phone as manager', () async {
      final code = JoinCode.parse(
        JoinCode(partnership: 'p1', investorKey: investorKey).encode(),
      );

      await joinPartnership(code: code, store: store, ownKeys: texts.manager);

      final validator = store.validatorFor('p1');
      expect(validator.pinnedInvestorKey, investorKey);
      expect(validator.pinnedManagerKey, texts.manager.publicKeyBase64Url);
    });

    test(
      'a forged create arriving first is refused, then the real one is accepted',
      () async {
        await joinPartnership(
          code: JoinCode(partnership: 'p1', investorKey: investorKey),
          store: store,
          ownKeys: texts.manager,
        );
        final attacker = await generateEd25519KeyPair();
        final forged = await texts.forgedCreate(attacker: attacker);
        final real = await texts.partnershipCreate();

        expect(await store.receive(forged), ReceiveOutcome.rejectedMembership);
        expect(await store.receive(real), ReceiveOutcome.accepted);
        expect(await store.savedTexts('p1'), [real]);
      },
    );

    test('a phone holding the investor key cannot join as manager', () async {
      await expectLater(
        joinPartnership(
          code: JoinCode(partnership: 'p1', investorKey: investorKey),
          store: store,
          ownKeys: texts.investor,
        ),
        throwsArgumentError,
      );
      expect(store.partnerships, isEmpty);
    });

    test('joining twice with the same code changes nothing', () async {
      final code = JoinCode(partnership: 'p1', investorKey: investorKey);

      await joinPartnership(code: code, store: store, ownKeys: texts.manager);
      await joinPartnership(code: code, store: store, ownKeys: texts.manager);

      expect(store.partnerships, ['p1']);
    });
  });
}
