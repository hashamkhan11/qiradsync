import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/onboarding/safety_code_dialog.dart';
import 'package:qirad_core/qirad_core.dart';

void main() {
  late String investorKey;
  late String managerKey;

  setUp(() async {
    investorKey = (await generateEd25519KeyPair()).publicKeyBase64Url;
    managerKey = (await generateEd25519KeyPair()).publicKeyBase64Url;
  });

  /// Opens the dialog from a button and records what it returned.
  Future<void> openDialog(WidgetTester tester, List<bool?> results) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              results.add(
                await confirmSafetyCode(
                  context,
                  investorKey: investorKey,
                  managerKey: managerKey,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('shows the code computed from both keys, investor first', (
    tester,
  ) async {
    await openDialog(tester, []);

    final shown = tester.widget<SelectableText>(
      find.byKey(const Key('safety-code')),
    );
    expect(
      shown.data,
      safetyCode(investorKey: investorKey, managerKey: managerKey),
    );
  });

  testWidgets('"Codes match" returns true', (tester) async {
    final results = <bool?>[];
    await openDialog(tester, results);

    await tester.tap(find.text('Codes match'));
    await tester.pumpAndSettle();

    expect(results, [true]);
  });

  testWidgets('"Cancel" returns false', (tester) async {
    final results = <bool?>[];
    await openDialog(tester, results);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(results, [false]);
  });

  testWidgets('a tap outside the dialog does not confirm it', (tester) async {
    final results = <bool?>[];
    await openDialog(tester, results);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    // The dialog is still open, so nothing has returned yet.
    expect(find.text('Codes match'), findsOneWidget);
    expect(results, isEmpty);
  });
}
