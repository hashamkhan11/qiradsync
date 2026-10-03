import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

List<Decision> _decide(Validator validator) => decideApprovals(
      validator.usableRecords,
      partnershipKeys: validator.partnershipKeys!,
    );

Decision _decisionFor(List<Decision> decisions, Record target) =>
    decisions.singleWhere((d) => d.target.id == target.id);

void main() {
  group('first response wins (spec section 5)', () {
    test('an approve as the first response makes the proposal active', () async {
      final (validator, investor, manager, partnershipId) = await setUpPartnership();
      final proposal = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 10000},
      );
      final approve = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: proposal.id,
      );
      expect(await validator.receiveText(canonicalJson(proposal.toJson())), ReceiveOutcome.accepted);
      expect(await validator.receiveText(canonicalJson(approve.toJson())), ReceiveOutcome.accepted);

      final decision = _decisionFor(_decide(validator), proposal);

      expect(decision.status, DecisionStatus.active);
      expect(decision.firstResponse?.id, approve.id);
    });

    test('a reject as the first response makes the proposal dead', () async {
      final (validator, investor, manager, partnershipId) = await setUpPartnership();
      final proposal = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 10000},
      );
      final reject = await manager.next(
        partnership: partnershipId,
        type: 'reject',
        refersTo: proposal.id,
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));
      await validator.receiveText(canonicalJson(reject.toJson()));

      final decision = _decisionFor(_decide(validator), proposal);

      expect(decision.status, DecisionStatus.dead);
    });

    test('a proposal with no response yet is pending', () async {
      final (validator, investor, manager, partnershipId) = await setUpPartnership();
      final proposal = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 10000},
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));

      final decision = _decisionFor(_decide(validator), proposal);

      expect(decision.status, DecisionStatus.pending);
      expect(decision.firstResponse, isNull);
    });

    test('a later response is kept as ignored evidence and does not change the status', () async {
      final (validator, investor, manager, partnershipId) = await setUpPartnership();
      final proposal = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 10000},
      );
      final approve = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: proposal.id,
      );
      final lateReject = await manager.next(
        partnership: partnershipId,
        type: 'reject',
        refersTo: proposal.id,
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));
      await validator.receiveText(canonicalJson(approve.toJson()));
      await validator.receiveText(canonicalJson(lateReject.toJson()));

      final decision = _decisionFor(_decide(validator), proposal);

      expect(decision.status, DecisionStatus.active);
      expect(decision.ignoredResponses.map((r) => r.id), [lateReject.id]);
    });

    test('a reject that arrives before the approve does not change the outcome', () async {
      final (validator, investor, manager, partnershipId) = await setUpPartnership();
      final proposal = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 10000},
      );
      final approve = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: proposal.id,
      );
      final reject = await manager.next(
        partnership: partnershipId,
        type: 'reject',
        refersTo: proposal.id,
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));

      // The later response (seq 2) arrives first, so it waits in the pending buffer.
      expect(await validator.receiveText(canonicalJson(reject.toJson())), ReceiveOutcome.pending);
      expect(await validator.receiveText(canonicalJson(approve.toJson())), ReceiveOutcome.accepted);

      final decision = _decisionFor(_decide(validator), proposal);

      expect(decision.status, DecisionStatus.active);
      expect(decision.firstResponse?.id, approve.id);
      expect(decision.ignoredResponses.map((r) => r.id), [reject.id]);
    });
  });

  group('who may respond', () {
    test('a partner approving their own proposal does not count', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final proposal = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': investor.key, 'amount': 10000},
      );
      final selfApprove = await investor.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: proposal.id,
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));
      await validator.receiveText(canonicalJson(selfApprove.toJson()));

      final decision = _decisionFor(_decide(validator), proposal);

      expect(decision.status, DecisionStatus.pending);
      expect(decision.ignoredResponses, isEmpty);
    });

    test('responses from an equivocating partner do not count', () async {
      final (validator, investor, manager, partnershipId) = await setUpPartnership();
      final proposal = await investor.next(
        partnership: partnershipId,
        type: 'budget_proposal',
        body: {'grantee': manager.key, 'amount': 10000},
      );
      final approve = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: proposal.id,
      );
      manager.seq -= 1; // manager re-signs a different response at the same seq
      final forgedReject = await manager.next(
        partnership: partnershipId,
        type: 'reject',
        refersTo: proposal.id,
      );
      await validator.receiveText(canonicalJson(proposal.toJson()));
      await validator.receiveText(canonicalJson(approve.toJson()));
      expect(await validator.receiveText(canonicalJson(forgedReject.toJson())), ReceiveOutcome.equivocating);

      final decision = _decisionFor(_decide(validator), proposal);

      expect(decision.status, DecisionStatus.pending);
    });
  });
}
