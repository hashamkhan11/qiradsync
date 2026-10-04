import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/onboarding/onboarding_screen.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory dir;
  late RecordStore store;
  late Ed25519KeyPair keys;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('qirad_onboarding_test');
    store = await RecordStore.open(
      factory: databaseFactoryFfi,
      path: p.join(dir.path, 'records.db'),
    );
    keys = await generateEd25519KeyPair();
  });

  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  Future<void> pumpScreen(WidgetTester tester) async {
    // A tall window, so the error text at the bottom of the list is built.
    await tester.binding.setSurfaceSize(const Size(800, 2400));
    await tester.pumpWidget(
      MaterialApp(
        home: OnboardingScreen(store: store, keys: keys, onReady: (_) {}),
      ),
    );
  }

  testWidgets('shows the phone key so the partner can pin it', (tester) async {
    await pumpScreen(tester);

    expect(find.text(keys.publicKeyBase64Url), findsOneWidget);
  });

  testWidgets('a bad manager key shows an error and saves nothing', (
    tester,
  ) async {
    await pumpScreen(tester);

    await tester.enterText(
      find.widgetWithText(TextField, "Manager's key"),
      'oops',
    );
    await tester.ensureVisible(find.text('Create partnership'));
    await tester.tap(find.text('Create partnership'));
    await tester.pumpAndSettle();

    expect(find.text('not a valid key'), findsOneWidget);
    expect(store.partnerships, isEmpty);
  });

  testWidgets('a join code that does not parse shows an error', (tester) async {
    await pumpScreen(tester);

    await tester.enterText(
      find.widgetWithText(TextField, 'Join code from the investor'),
      'not-a-code',
    );
    await tester.ensureVisible(find.text('Join partnership'));
    await tester.tap(find.text('Join partnership'));
    await tester.pumpAndSettle();

    expect(find.text('not a join code'), findsOneWidget);
    expect(store.partnerships, isEmpty);
  });
}
