import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

/// An unsaved approve by [author] of [targetId], built on [usable] the same way
/// a phone builds its own record. It is only an input to the summary.
Record _candidateApprove(
  Iterable<Record> usable,
  String author,
  String partnership,
  String targetId,
) => buildRecord(
  ledger: usable,
  author: author,
  partnership: partnership,
  id: testId('candidate-approve-$targetId'),
  type: 'approve',
  body: const {},
  time: '2026-10-06T10:00:00Z',
  refersTo: targetId,
);

void main() {
  group('consent summary (spec 6.7, step 4)', () {
    test(
      'a settlement summary equals the period core reports once it is effective',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final keys = {investor.key, manager.key};

        // Records that make a period with a result: an invest and a sale.
        expect(
          await validator.receiveText(
            canonicalJson(
              (await investor.next(
                partnership: partnership,
                type: 'invest',
                body: {'amount': 100000},
              )).toJson(),
            ),
          ),
          ReceiveOutcome.accepted,
        );
        expect(
          await validator.receiveText(
            canonicalJson(
              (await manager.next(
                partnership: partnership,
                type: 'sale',
                body: {'amount': 50000},
              )).toJson(),
            ),
          ),
          ReceiveOutcome.accepted,
        );

        // The manager proposes the settlement. The cut covers the investor's
        // seqs 1 and 2 and the manager's seq 1.
        final proposal = await manager.next(
          partnership: partnership,
          type: 'settlement',
          body: {
            'cut': {investor.key: 2, manager.key: 1},
          },
        );
        expect(
          await validator.receiveText(canonicalJson(proposal.toJson())),
          ReceiveOutcome.accepted,
        );

        // Before the answer: the summary uses an unsaved approve as input.
        final candidate = _candidateApprove(
          validator.usableRecords,
          investor.key,
          partnership,
          proposal.id,
        );
        final summary = settlementConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          proposal: proposal,
          answer: candidate,
        );
        expect(summary, isNotNull);

        // The real approve is saved. Now core reports the settled period.
        final real = await investor.next(
          partnership: partnership,
          type: 'approve',
          refersTo: proposal.id,
        );
        expect(
          await validator.receiveText(canonicalJson(real.toJson())),
          ReceiveOutcome.accepted,
        );
        final closed = periodShares(
          validator.usableRecords,
          partnershipKeys: keys,
        ).where((p) => !p.open).toList();
        final settled = closed.single;

        expect(summary!.periodIndex, settled.index);
        expect(summary.result, settled.result);
        expect(summary.shares.investor, settled.shares.investor);
        expect(summary.shares.manager, settled.shares.manager);
        expect(summary.ratio, settled.ratio);
        expect(
          summary.result,
          summary.shares.investor + summary.shares.manager,
        );
      },
    );

    test('a reject as the answer gives no summary, so no Approve', () async {
      final (validator, investor, manager, partnership) =
          await setUpPartnership();
      final proposal = await manager.next(
        partnership: partnership,
        type: 'settlement',
        body: {
          'cut': {investor.key: 1, manager.key: 0},
        },
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));

      final reject = Record(
        v: 1,
        id: testId('candidate-reject'),
        partnership: partnership,
        author: investor.key,
        seq: 2,
        prevHash: recordHash(
          validator.usableRecords
              .firstWhere((r) => r.author == investor.key)
              .toJson(),
        ),
        type: 'reject',
        body: const {},
        refersTo: proposal.id,
        note: '',
        time: '2026-10-06T10:00:00Z',
        sig: '',
      );

      final summary = settlementConsent(
        validator.usableRecords,
        partnershipKeys: {investor.key, manager.key},
        proposal: proposal,
        answer: reject,
      );
      expect(summary, isNull);
    });

    test(
      'a withdrawal summary equals the totals core reports once it is effective',
      () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final keys = {investor.key, manager.key};

        // The manager asks for a profit withdrawal of 1000.
        final request = await manager.next(
          partnership: partnership,
          type: 'withdraw_request',
          body: {'amount': 1000, 'kind': 'profit'},
        );
        await validator.receiveText(canonicalJson(request.toJson()));

        // Before the answer: the summary uses an unsaved investor approve.
        final candidate = _candidateApprove(
          validator.usableRecords,
          investor.key,
          partnership,
          request.id,
        );
        final summary = withdrawalConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          request: request,
          answer: candidate,
        );
        expect(summary, isNotNull);
        expect(summary!.amount, 1000);
        expect(summary.kind, 'profit');

        // The real approve is saved. The totals must match core's.
        final real = await investor.next(
          partnership: partnership,
          type: 'approve',
          refersTo: request.id,
        );
        await validator.receiveText(canonicalJson(real.toJson()));
        final total = totalProfitWithdrawn(
          validator.usableRecords,
          partnershipKeys: keys,
        );
        expect(summary.totalProfitWithdrawn, total[manager.key]);
      },
    );
  });
}
