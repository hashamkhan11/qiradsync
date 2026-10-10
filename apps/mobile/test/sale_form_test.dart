import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/create/sale_form.dart';

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
        home: SaleForm(
          store: fixture.store,
          writer: asManager ? fixture.managerWriter() : fixture.investorWriter(),
          partnership: fixture.partnership,
          onSyncNow: () async {},
        ),
      ),
    );
  }

  group('SaleForm (spec section 5)', () {
    testWidgets('the investor is refused: sale is manager only', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await pump(tester, asManager: false);
        await tester.enterText(find.byType(TextField), '500');
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find.text('Your role cannot propose this.').evaluate().isNotEmpty,
        );
      });
    });

    testWidgets('a valid amount previews and saves a sale record', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await pump(tester, asManager: true);
        await tester.enterText(find.byType(TextField), '1,000');
        await tester.pump();

        expect(find.text('Rs 1,000.00'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find.widgetWithText(FilledButton, 'Save').evaluate().isEmpty,
        );

        final saved = await fixture.savedRecords();
        final sale = saved.where((r) => r.type == 'sale');
        expect(sale, hasLength(1));
        expect(sale.single.body['amount'], 100000);
      });
    });

    testWidgets('refused before the partnership is active', (tester) async {
      await tester.runAsync(() async {
        final other = await CreateFixture.open();
        await other.startWithUnapprovedCreate();

        await tester.binding.setSurfaceSize(const Size(800, 1600));
        await tester.pumpWidget(
          MaterialApp(
            home: SaleForm(
              store: other.store,
              writer: other.managerWriter(),
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
