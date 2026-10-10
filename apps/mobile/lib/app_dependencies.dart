import 'package:qirad_core/qirad_core.dart';

import 'storage/key_store.dart';
import 'storage/record_store.dart';
import 'storage/record_writer.dart';
import 'storage/token_store.dart';
import 'sync/device_session.dart';
import 'sync/relay_client.dart';
import 'sync/relay_url.dart';
import 'sync/sync_runner.dart';

/// Everything the app builds once at startup (spec 7.2-7.4), gathered here so
/// `main.dart` stays a thin entry point and this wiring has its own tests,
/// not just whatever a widget test happens to exercise.
class AppDependencies {
  AppDependencies({
    required this.store,
    required this.keys,
    required this.relay,
    required this.session,
    required this.syncRunner,
  });

  final RecordStore store;
  final Ed25519KeyPair keys;
  final RelayClient relay;
  final DeviceSession session;
  final SyncRunner syncRunner;

  /// One [RecordWriter] per partnership, for the life of the app.
  ///
  /// `RecordStore.appendWith` only serialises writes made through the *same*
  /// writer instance. Two separate writers for one partnership share no
  /// lock: both could read the same chain tail and sign the same next seq,
  /// forking the chain (spec 7.4). This cache is what stops a second writer
  /// for a partnership from ever being built, so every caller — including
  /// the one that runs right after onboarding completes — gets back the one
  /// writer that already exists.
  final Map<String, RecordWriter> _writers = {};

  RecordWriter writerFor(String partnership) => _writers.putIfAbsent(
    partnership,
    () => RecordWriter.forPartnership(
      keys: keys,
      partnership: partnership,
      store: store,
    ),
  );

  /// Builds every startup dependency from [relayUrl]. Throws [RelayUrlError]
  /// if [relayUrl] is missing or not allowed; the caller shows that message
  /// instead of starting the app (spec 7.2).
  ///
  /// [debug] is a parameter (pass `kDebugMode` from `main.dart`) rather than
  /// read here, so this factory is a plain, directly testable function.
  static AppDependencies create({
    required String relayUrl,
    required bool debug,
    required RecordStore store,
    required Ed25519KeyPair keys,
    required SecretStore secrets,
  }) {
    final baseUrl = validateRelayUrl(relayUrl, debug: debug);
    final relay = RelayClient.live(baseUrl: baseUrl.toString());
    final session = DeviceSession(
      keys: keys,
      relay: relay,
      tokens: TokenStore(secrets),
    );
    final syncRunner = SyncRunner(store: store, relay: relay, session: session);
    return AppDependencies(
      store: store,
      keys: keys,
      relay: relay,
      session: session,
      syncRunner: syncRunner,
    );
  }
}
