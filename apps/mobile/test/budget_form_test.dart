import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/create/budget_form.dart';

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
        home: BudgetForm(
          store: fixture.store,
          writer: asManager ? fixture.managerWriter() : fixture.investorWriter(),
          myKey: asManager
              ? fixture.manager.publicKeyBase64Url
              : fixture.investor.publicKeyBase64Url,
          partnership: fixture.partnership,
          onSyncNow: () async {},
        ),
      ),
    );
  }

  group('BudgetForm (spec section 5, 6.4)', () {
    testWidgets(
      'open to either partner: the investor can propose one for the manager',
      (tester) async {
        await tester.runAsync(() async {
          await pump(tester, asManager: false);
          await tester.tap(find.text('For the other partner'));
          await tester.pump();
          await tester.enterText(find.byType(TextField), '2,000');
          await tester.pump();

          expect(find.text('Rs 2,000.00'), findsOneWidget);

          await tester.tap(find.widgetWithText(FilledButton, 'Save'));
          await pumpUntil(
            tester,
            () => find.widgetWithText(FilledButton, 'Save').evaluate().isEmpty,
          );

          final saved = await fixture.savedRecords();
          final budget = saved.where((r) => r.type == 'budget_proposal');
          expect(budget, hasLength(1));
          expect(
            budget.single.body['grantee'],
            fixture.manager.publicKeyBase64Url,
          );
          expect(budget.single.body['amount'], 200000);
        });
      },
    );

    testWidgets('a valid amount previews and saves for myself by default', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await pump(tester, asManager: true);
        await tester.enterText(find.byType(TextField), '300');
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find.widgetWithText(FilledButton, 'Save').evaluate().isEmpty,
        );

        final saved = await fixture.savedRecords();
        final budget = saved.where((r) => r.type == 'budget_proposal');
        expect(budget, hasLength(1));
        expect(
          budget.single.body['grantee'],
          fixture.manager.publicKeyBase64Url,
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
            home: BudgetForm(
              store: other.store,
              writer: other.investorWriter(),
              myKey: other.investor.publicKeyBase64Url,
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
