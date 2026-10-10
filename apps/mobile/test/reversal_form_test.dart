import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/create/reversal_form.dart';

import 'support/create_fixture.dart';
import 'support/pump_until.dart';

void main() {
  late CreateFixture fixture;

  setUp(() async {
    fixture = await CreateFixture.open();
  });

  tearDown(() => fixture.close());

  Future<void> pump(WidgetTester tester, {required bool asManager}) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    await tester.pumpWidget(
      MaterialApp(
        home: ReversalForm(
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

  group('ReversalForm (spec section 5)', () {
    testWidgets(
      'nothing to reverse yet says so clearly, instead of an empty form',
      (tester) async {
        await tester.runAsync(() async {
          await fixture.startWithCreate();
          await pump(tester, asManager: false);

          expect(
            find.text('Nothing on this phone can be reversed yet.'),
            findsOneWidget,
          );
          expect(find.byType(FilledButton), findsNothing);
        });
      },
    );

    testWidgets(
      'open to either partner: the manager reverses the investor\'s invest',
      (tester) async {
        await tester.runAsync(() async {
          await fixture.startWithCreate();
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

          expect(find.textContaining('invest Rs 1,000.00'), findsWidgets);

          await tester.tap(find.widgetWithText(FilledButton, 'Save'));
          await pumpUntil(
            tester,
            () => find.widgetWithText(FilledButton, 'Save').evaluate().isEmpty,
          );

          final saved = await fixture.savedRecords();
          final reversal = saved.where((r) => r.type == 'reversal');
          expect(reversal, hasLength(1));
          expect(reversal.single.refersTo, invest.id);
        });
      },
    );

    testWidgets('refused before the partnership is active', (tester) async {
      await tester.runAsync(() async {
        await fixture.startWithUnapprovedCreate();
        final invest = await fixture.write(
          fixture.investor,
          fixture.investorChain,
          id: 'early-invest',
          type: 'invest',
          body: const {'amount': 50000},
        );
        await fixture.receive(invest);

        await pump(tester, asManager: false);
        await tester.pump();

        await tester.tap(find.widgetWithText(FilledButton, 'Save'));
        await pumpUntil(
          tester,
          () => find
              .text('The partnership is not active yet.')
              .evaluate()
              .isNotEmpty,
        );
      });
    });
  });
}
