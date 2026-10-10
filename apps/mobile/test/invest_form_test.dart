import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/create/invest_form.dart';

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
        home: InvestForm(
          store: fixture.store,
          writer: asManager ? fixture.managerWriter() : fixture.investorWriter(),
          partnership: fixture.partnership,
          onSyncNow: () async {},
        ),
      ),
    );
  }

  group('InvestForm (spec section 5)', () {
    testWidgets('the manager is refused: invest is investor only', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await pump(tester, asManager: true);
        await tester.enterText(find.byType(TextField), '500');
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find.text('Your role cannot propose this.').evaluate().isNotEmpty,
        );
      });
    });

    testWidgets('a valid amount previews and saves an invest record', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await pump(tester, asManager: false);
        await tester.enterText(find.byType(TextField), '1,500.50');
        await tester.pump();

        expect(find.text('Rs 1,500.50'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find.widgetWithText(FilledButton, 'Save').evaluate().isEmpty,
        );

        final saved = await fixture.savedRecords();
        final invest = saved.where((r) => r.type == 'invest');
        expect(invest, hasLength(1));
        expect(invest.single.body['amount'], 150050);
      });
    });

    testWidgets('refused before the partnership is active', (tester) async {
      await tester.runAsync(() async {
        final other = await CreateFixture.open();
        await other.startWithUnapprovedCreate();

        await tester.binding.setSurfaceSize(const Size(800, 1600));
        await tester.pumpWidget(
          MaterialApp(
            home: InvestForm(
              store: other.store,
              writer: other.investorWriter(),
              partnership: other.partnership,
              onSyncNow: () async {},
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
