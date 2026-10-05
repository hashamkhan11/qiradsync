import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite/sqflite.dart';

import 'dashboard/dashboard_screen.dart';
import 'onboarding/onboarding_screen.dart';
import 'storage/key_store.dart';
import 'storage/record_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await RecordStore.open(
    factory: databaseFactory,
    path: p.join(await getDatabasesPath(), 'qirad.db'),
  );
  final keys = await KeyStore(PlatformSecretStore()).loadOrCreate();
  runApp(QiradApp(store: store, keys: keys));
}

/// The app root. It shows onboarding until this phone has a partnership.
class QiradApp extends StatefulWidget {
  const QiradApp({super.key, required this.store, required this.keys});

  final RecordStore store;
  final Ed25519KeyPair keys;

  @override
  State<QiradApp> createState() => _QiradAppState();
}

class _QiradAppState extends State<QiradApp> {
  late bool _hasPartnership = widget.store.partnerships.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'QiradSync',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.teal)),
      home: _hasPartnership
          ? DashboardScreen(
              store: widget.store,
              partnership: widget.store.partnerships.first,
            )
          : OnboardingScreen(
              store: widget.store,
              keys: widget.keys,
              onReady: (_) => setState(() => _hasPartnership = true),
            ),
    );
  }
}
