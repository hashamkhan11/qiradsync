import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/create/withdrawal_form.dart';

import 'support/create_fixture.dart';
import 'support/pump_until.dart';

void main() {
  late CreateFixture fixture;

  setUp(() async {
    fixture = await CreateFixture.open();
    await fixture.startWithCreate();
  });

  tearDown(() => fixture.close());

  Future<void> pump(
    WidgetTester tester, {
    required bool asManager,
    required String kind,
  }) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    await tester.pumpWidget(
      MaterialApp(
        home: WithdrawalForm(
          store: fixture.store,
          writer: asManager ? fixture.managerWriter() : fixture.investorWriter(),
          partnership: fixture.partnership,
          onSyncNow: () async {},
          kind: kind,
        ),
      ),
    );
  }

  group('WithdrawalForm (spec section 5; decision 2026-10-10)', () {
    testWidgets(
      'the manager is refused a capital withdrawal: investor only',
      (tester) async {
        await tester.runAsync(() async {
          await pump(tester, asManager: true, kind: 'capital');
          await tester.enterText(find.byType(TextField), '500');
          await tester.pump();

          await tester.tap(find.widgetWithText(FilledButton, 'Save'));
          await pumpUntil(
            tester,
            () =>
                find.text('Your role cannot propose this.').evaluate().isNotEmpty,
          );
        });
      },
    );

    testWidgets('the investor saves a capital withdrawal request', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await pump(tester, asManager: false, kind: 'capital');
        await tester.enterText(find.byType(TextField), '250');
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find.widgetWithText(FilledButton, 'Save').evaluate().isEmpty,
        );

        final saved = await fixture.savedRecords();
        final request = saved.where((r) => r.type == 'withdraw_request');
        expect(request, hasLength(1));
        expect(request.single.body['kind'], 'capital');
        expect(request.single.body['amount'], 25000);
      });
    });

    testWidgets('the manager saves a profit withdrawal request too', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await pump(tester, asManager: true, kind: 'profit');
        await tester.enterText(find.byType(TextField), '100');
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find.widgetWithText(FilledButton, 'Save').evaluate().isEmpty,
        );

        final saved = await fixture.savedRecords();
        final request = saved.where((r) => r.type == 'withdraw_request');
        expect(request, hasLength(1));
        expect(request.single.body['kind'], 'profit');
      });
    });

    testWidgets('refused before the partnership is active', (tester) async {
      await tester.runAsync(() async {
        final other = await CreateFixture.open();
        await other.startWithUnapprovedCreate();

        await tester.binding.setSurfaceSize(const Size(800, 1600));
        await tester.pumpWidget(
          MaterialApp(
            home: WithdrawalForm(
              store: other.store,
              writer: other.investorWriter(),
              partnership: other.partnership,
              onSyncNow: () async {},
              kind: 'capital',
            ),
          ),
        );
        await tester.enterText(find.byType(TextField), '500');
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find
              .text('The partnership is not active yet.')
              .evaluate()
              .isNotEmpty,
        );
        await other.close();
      });
    });
  });
}
