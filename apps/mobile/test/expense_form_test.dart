import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/create/expense_form.dart';

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
        home: ExpenseForm(
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

  group('ExpenseForm (spec section 5, 6.4)', () {
    testWidgets(
      'no budget granted yet shows a fallback, instead of an empty form',
      (tester) async {
        await tester.runAsync(() async {
          await pump(tester, asManager: true);
          await tester.pump();

          expect(
            find.textContaining('No approved budget is granted to you yet'),
            findsOneWidget,
          );
          expect(find.byType(FilledButton), findsNothing);
        });
      },
    );

    testWidgets('the investor is refused: expense is manager only', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final budget = await fixture.write(
          fixture.manager,
          fixture.managerChain,
          id: 'budget-1',
          type: 'budget_proposal',
          body: {
            'grantee': fixture.investor.publicKeyBase64Url,
            'amount': 500000,
          },
        );
        await fixture.receive(budget);
        await fixture.receive(
          await fixture.write(
            fixture.investor,
            fixture.investorChain,
            id: 'approve-budget-1',
            type: 'approve',
            refersTo: budget.id,
          ),
        );

        await pump(tester, asManager: false);
        await tester.pump();
        await tester.enterText(find.byType(TextField).last, '1,000');
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () =>
              find.text('Your role cannot propose this.').evaluate().isNotEmpty,
        );
      });
    });

    testWidgets('a valid amount previews and saves an expense record', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final budget = await fixture.write(
          fixture.investor,
          fixture.investorChain,
          id: 'budget-1',
          type: 'budget_proposal',
          body: {
            'grantee': fixture.manager.publicKeyBase64Url,
            'amount': 500000,
          },
        );
        await fixture.receive(budget);
        await fixture.receive(
          await fixture.write(
            fixture.manager,
            fixture.managerChain,
            id: 'approve-budget-1',
            type: 'approve',
            refersTo: budget.id,
          ),
        );

        await pump(tester, asManager: true);
        await tester.pump();
        await tester.enterText(find.byType(TextField).last, '1,000');
        await tester.pump();

        expect(find.text('Rs 1,000.00'), findsOneWidget);

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find.widgetWithText(FilledButton, 'Save').evaluate().isEmpty,
        );

        final saved = await fixture.savedRecords();
        final expense = saved.where((r) => r.type == 'expense');
        expect(expense, hasLength(1));
        expect(expense.single.refersTo, budget.id);
        expect(expense.single.body['amount'], 100000);
      });
    });

    testWidgets(
      'before the partnership is active, there is no budget to spend from',
      (tester) async {
        await tester.runAsync(() async {
          final other = await CreateFixture.open();
          await other.startWithUnapprovedCreate();

          await tester.binding.setSurfaceSize(const Size(800, 1600));
          await tester.pumpWidget(
            MaterialApp(
              home: ExpenseForm(
                store: other.store,
                writer: other.managerWriter(),
                myKey: other.manager.publicKeyBase64Url,
                partnership: other.partnership,
                onSyncNow: () async {},
              ),
            ),
          );
          await tester.pump();

          expect(
            find.textContaining('No approved budget is granted to you yet'),
            findsOneWidget,
          );
          expect(find.byType(FilledButton), findsNothing);
          await other.close();
        });
      },
    );
  });
}
