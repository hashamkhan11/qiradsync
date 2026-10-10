import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/create/settlement_form.dart';

import 'support/create_fixture.dart';
import 'support/pump_until.dart';

void main() {
  late CreateFixture fixture;

  setUp(() async {
    fixture = await CreateFixture.open();
    await fixture.startWithCreate();
  });

  tearDown(() => fixture.close());

  Future<void> pump(WidgetTester tester, {required bool asManager}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    await tester.pumpWidget(
      MaterialApp(
        home: SettlementForm(
          store: fixture.store,
          writer: asManager ? fixture.managerWriter() : fixture.investorWriter(),
          partnership: fixture.partnership,
          onSyncNow: () async {},
        ),
      ),
    );
  }

  group('SettlementForm (spec 6.7)', () {
    testWidgets('shows the open period and the manager saves a settlement', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final invest = await fixture.write(
          fixture.investor,
          fixture.investorChain,
          id: 'invest-1',
          type: 'invest',
          body: const {'amount': 100000},
        );
        await fixture.receive(invest);

        await pump(tester, asManager: true);
        await tester.pump();

        expect(find.text('Open period result'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find.widgetWithText(FilledButton, 'Save').evaluate().isEmpty,
        );

        final saved = await fixture.savedRecords();
        final settlement = saved.where((r) => r.type == 'settlement');
        expect(settlement, hasLength(1));
        expect(settlement.single.body['cut'], isNotNull);
      });
    });

    testWidgets('the investor is refused: settlement is manager only', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await pump(tester, asManager: false);
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () =>
              find.text('Your role cannot propose this.').evaluate().isNotEmpty,
        );
      });
    });

    testWidgets('refused before the partnership is active', (tester) async {
      await tester.runAsync(() async {
        final other = await CreateFixture.open();
        await other.startWithUnapprovedCreate();

        await tester.binding.setSurfaceSize(const Size(800, 1600));
        await tester.pumpWidget(
          MaterialApp(
            home: SettlementForm(
              store: other.store,
              writer: other.managerWriter(),
              partnership: other.partnership,
              onSyncNow: () async {},
            ),
          ),
        );
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
