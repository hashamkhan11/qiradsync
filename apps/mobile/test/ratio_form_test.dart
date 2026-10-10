import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/create/ratio_form.dart';

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
        home: RatioForm(
          store: fixture.store,
          writer: asManager ? fixture.managerWriter() : fixture.investorWriter(),
          partnership: fixture.partnership,
          onSyncNow: () async {},
        ),
      ),
    );
  }

  Future<void> pickTodayAsEffectiveDate(WidgetTester tester) async {
    await tester.tap(find.text('Choose the effective date'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  group('RatioForm (spec section 5)', () {
    testWidgets('open to either partner: the investor can propose one', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await pump(tester, asManager: false);
        await tester.enterText(find.byType(TextField), '70');
        await tester.pump();
        await pickTodayAsEffectiveDate(tester);

        expect(find.text('70/30'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find.widgetWithText(FilledButton, 'Save').evaluate().isEmpty,
        );

        final saved = await fixture.savedRecords();
        final ratio = saved.where((r) => r.type == 'ratio_proposal');
        expect(ratio, hasLength(1));
        expect(ratio.single.body['ratio'], {'investor': 70, 'manager': 30});
      });
    });

    testWidgets('the manager can propose one too', (tester) async {
      await tester.runAsync(() async {
        await pump(tester, asManager: true);
        await tester.enterText(find.byType(TextField), '40');
        await tester.pump();
        await pickTodayAsEffectiveDate(tester);

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find.widgetWithText(FilledButton, 'Save').evaluate().isEmpty,
        );

        final saved = await fixture.savedRecords();
        final ratio = saved.where((r) => r.type == 'ratio_proposal');
        expect(ratio, hasLength(1));
        expect(ratio.single.body['ratio'], {'investor': 40, 'manager': 60});
      });
    });

    testWidgets('refused before the partnership is active', (tester) async {
      await tester.runAsync(() async {
        final other = await CreateFixture.open();
        await other.startWithUnapprovedCreate();

        await tester.binding.setSurfaceSize(const Size(800, 1600));
        await tester.pumpWidget(
          MaterialApp(
            home: RatioForm(
              store: other.store,
              writer: other.investorWriter(),
              partnership: other.partnership,
              onSyncNow: () async {},
            ),
          ),
        );
        await tester.enterText(find.byType(TextField), '50');
        await tester.pump();
        await pickTodayAsEffectiveDate(tester);

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
