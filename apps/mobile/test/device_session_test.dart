import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/storage/token_store.dart';
import 'package:mobile/sync/device_session.dart';
import 'package:mobile/sync/relay_client.dart';
import 'package:qirad_core/qirad_core.dart';

import 'support/fake_relay.dart';
import 'support/fake_secret_store.dart';

void main() {
  late FakeRelay relay;
  late FakeSecretStore secrets;
  late TokenStore tokens;
  late DeviceSession session;

  setUp(() async {
    relay = FakeRelay();
    secrets = FakeSecretStore();
    tokens = TokenStore(secrets);
    session = DeviceSession(
      keys: await generateEd25519KeyPair(),
      relay: RelayClient(
        baseUrl: 'https://relay.test',
        httpClient: relay.client,
      ),
      tokens: tokens,
    );
  });

  test('a device with no saved token registers and saves the token', () async {
    final token = await session.token();

    expect(token, 'token-1');
    expect(relay.challenges, 1);
    expect(relay.registrations, 1);
    expect(await tokens.load(), 'token-1');
  });

  test('a saved token is reused: no request to the relay', () async {
    final first = await session.token();
    final challengesBefore = relay.challenges;

    final second = await session.token();

    expect(second, first);
    expect(relay.challenges, challengesBefore);
    expect(relay.registrations, 1);
  });

  test(
    'the token is stored in the secure store, not in plain fields',
    () async {
      await session.token();

      expect(secrets.values.keys, ['qirad.device_token.v1']);
    },
  );

  test(
    'register() always asks for a new token and replaces the saved one',
    () async {
      final first = await session.token();

      final second = await session.register();

      expect(second, isNot(first));
      expect(await tokens.load(), second);
      expect(relay.registrations, 2);
    },
  );
}
