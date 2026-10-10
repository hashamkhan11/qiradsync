import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'app_dependencies.dart';
import 'dashboard/dashboard_screen.dart';
import 'onboarding/onboarding_screen.dart';
import 'storage/key_store.dart';
import 'storage/record_store.dart';
import 'sync/relay_url.dart';

/// Set at build time: `flutter run --dart-define=RELAY_URL=https://...`
/// (spec 7.2). Never hard-coded, so the same build cannot point at the wrong
/// server by accident.
const _relayUrl = String.fromEnvironment('RELAY_URL');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await RecordStore.open(
    factory: databaseFactory,
    path: p.join(await getDatabasesPath(), 'qirad.db'),
  );
  final secrets = PlatformSecretStore();
  final keys = await KeyStore(secrets).loadOrCreate();

  try {
    final deps = AppDependencies.create(
      relayUrl: _relayUrl,
      debug: kDebugMode,
      store: store,
      keys: keys,
      secrets: secrets,
    );
    runApp(QiradApp(deps: deps));
  } on RelayUrlError catch (e) {
    // Show the problem instead of throwing before runApp: a blank crash
    // screen tells the developer nothing, and this can only happen from how
    // the app was built, never from anything the user did.
    runApp(ConfigErrorApp(message: e.message));
  }
}

/// Shown instead of the app when the relay address is missing or not
/// allowed (spec 7.2).
class ConfigErrorApp extends StatelessWidget {
  const ConfigErrorApp({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'QiradSync cannot start.\n\n$message',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}

/// The app root. It shows onboarding until this phone has a partnership.
class QiradApp extends StatefulWidget {
  const QiradApp({super.key, required this.deps});

  final AppDependencies deps;

  @override
  State<QiradApp> createState() => _QiradAppState();
}

class _QiradAppState extends State<QiradApp> {
  late bool _hasPartnership = widget.deps.store.partnerships.isNotEmpty;
  String? _partnership;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QiradSync',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.teal)),
      home: _hasPartnership
          ? _Home(
              deps: widget.deps,
              partnership: _partnership ?? widget.deps.store.partnerships.first,
            )
          : OnboardingScreen(
              store: widget.deps.store,
              keys: widget.deps.keys,
              onReady: (id) => setState(() {
                _hasPartnership = true;
                _partnership = id;
              }),
            ),
    );
  }
}

/// The signed-in home. Syncs once as soon as it appears — so a brand-new
/// phone (just onboarded) already has the create record and a relay vector
/// before it tries to write anything, and never meets `notSynced` on its
/// first attempt — then shows the dashboard (spec 7.3, 7.4).
///
/// No timer anywhere: the only three sync triggers are this `initState`,
/// a successful write (handled inside `InboxScreen`, which also calls
/// `onSyncNow`), and the dashboard's own "Sync now" button, all sharing
/// this one `_sync` method so the badge is recomputed the same way after
/// each of them.
class _Home extends StatefulWidget {
  const _Home({required this.deps, required this.partnership});

  final AppDependencies deps;
  final String partnership;

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  Future<void> _sync() async {
    setState(() => _syncing = true);
    try {
      await widget.deps.syncRunner.run(widget.partnership);
    } catch (_) {
      // Best-effort only: a screen whose write actually needs a fresh sync
      // (RecordWriter's notSynced/chainBehindRelay refusals) shows its own
      // banner with its own retry, so this background attempt does not
      // need to surface an error of its own.
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DashboardScreen(
      store: widget.deps.store,
      partnership: widget.partnership,
      myKey: widget.deps.keys.publicKeyBase64Url,
      writer: widget.deps.writerFor(widget.partnership),
      syncing: _syncing,
      onSyncNow: _sync,
    );
  }
}
