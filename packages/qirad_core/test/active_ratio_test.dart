import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';
import 'support/test_ids.dart';

Future<ActiveRatio?> _activeRatio(Validator validator) async {
  final effectiveness = computeEffective(
    validator.usableRecords,
    partnershipKeys: validator.partnershipKeys!,
  );
  return activeRatio(validator.usableRecords, effectiveness: effectiveness);
}

Future<void> _receiveInOrder(Validator validator, List<Record> records) async {
  for (final record in records) {
    expect(
      await validator.receiveText(canonicalJson(record.toJson())),
      ReceiveOutcome.accepted,
      reason: record.id,
    );
  }
}

/// The investor proposes a ratio from [effectiveFrom], and the manager approves.
Future<(Record, Record)> _proposeRatio(
  ChainAuthor investor,
  ChainAuthor manager,
  String partnershipId, {
  required int investorPercent,
  required int managerPercent,
  required String effectiveFrom,
}) async {
  final proposal = await investor.next(
    partnership: partnershipId,
    type: 'ratio_proposal',
    body: {
      'ratio': {'investor': investorPercent, 'manager': managerPercent},
      'effectiveFrom': effectiveFrom,
    },
  );
  final approve = await manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: proposal.id,
  );
  return (proposal, approve);
}

/// The manager approves the investor's create. A partnership has no ratio
/// until this is effective.
Future<Record> _approveCreate(
  Validator validator,
  ChainAuthor manager,
  String partnershipId,
) async {
  final create = validator.usableRecords.singleWhere(
    (r) => r.type == 'partnership_create',
  );
  return manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: create.id,
  );
}

void main() {
  group('active ratio (spec section 6.6)', () {
    test('no ratio while the partnership is not approved', () async {
      final (validator, _, _, _) = await setUpPartnership();

      expect(await _activeRatio(validator), isNull);
    });

    test('the approved partnership_create gives the starting ratio', () async {
      final (validator, _, manager, partnershipId) = await setUpPartnership();
      final approve = await _approveCreate(validator, manager, partnershipId);
      await _receiveInOrder(validator, [approve]);

      final active = await _activeRatio(validator);

      expect(active!.ratio, const Ratio(investor: 60, manager: 40));
      expect(active.agreedStart, isNull);
    });

    test(
      'an effective proposal sets the ratio now, with its agreed start as text',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final approveCreate = await _approveCreate(
          validator,
          manager,
          partnershipId,
        );
        final (proposal, approve) = await _proposeRatio(
          investor,
          manager,
          partnershipId,
          investorPercent: 50,
          managerPercent: 50,
          effectiveFrom: '2026-11-01',
        );
        await _receiveInOrder(validator, [approveCreate, proposal, approve]);

        // The agreed date is shown as text. It is not compared with a clock, so
        // a change agreed for later is already the ratio in force.
        final active = await _activeRatio(validator);
        expect(active!.ratio, const Ratio(investor: 50, manager: 50));
        expect(active.agreedStart, '2026-11-01');
        expect(active.toString(), contains('agreed to start 2026-11-01'));
      },
    );

    test('a proposal that is not approved does not change the ratio', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final approveCreate = await _approveCreate(
        validator,
        manager,
        partnershipId,
      );
      final proposal = await investor.next(
        partnership: partnershipId,
        type: 'ratio_proposal',
        body: {
          'ratio': {'investor': 50, 'manager': 50},
          'effectiveFrom': '2026-09-01',
        },
      );
      await _receiveInOrder(validator, [approveCreate, proposal]);

      expect(
        (await _activeRatio(validator))!.ratio,
        const Ratio(investor: 60, manager: 40),
      );
    });

    test(
      'a proposal whose ratio does not add up to 100 is rejected, not stored',
      () async {
        // Spec section 5's schema step now enforces the sum rule here too,
        // the same as partnership_create (removing the old asymmetry where
        // a bad sum was only ignored later, by `ratioOf`).
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final approveCreate = await _approveCreate(
          validator,
          manager,
          partnershipId,
        );
        await _receiveInOrder(validator, [approveCreate]);
        final (proposal, _) = await _proposeRatio(
          investor,
          manager,
          partnershipId,
          investorPercent: 90,
          managerPercent: 20,
          effectiveFrom: '2026-09-01',
        );

        expect(
          await validator.receiveText(canonicalJson(proposal.toJson())),
          ReceiveOutcome.rejectedSchema,
        );
        expect(
          (await _activeRatio(validator))!.ratio,
          const Ratio(investor: 60, manager: 40),
        );
      },
    );

    test(
      'a bad-sum ratio is still ignored by activeRatio if it reaches the '
      'business layer some other way (defense in depth)',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final approveCreate = await _approveCreate(
          validator,
          manager,
          partnershipId,
        );
        await _receiveInOrder(validator, [approveCreate]);

        // A validly-signed proposal and approve, with the ratio corrupted
        // afterwards, without going through the validator, so this never
        // touches the schema check above.
        final (validProposal, validApprove) = await _proposeRatio(
          investor,
          manager,
          partnershipId,
          investorPercent: 50,
          managerPercent: 50,
          effectiveFrom: '2026-09-01',
        );
        final proposal = validProposal.copyWith(
          body: {
            'ratio': {'investor': 90, 'manager': 20},
            'effectiveFrom': '2026-09-01',
          },
        );

        final records = [...validator.usableRecords, proposal, validApprove];
        final effectiveness = computeEffective(
          records,
          partnershipKeys: validator.partnershipKeys!,
        );
        final active = activeRatio(records, effectiveness: effectiveness);

        expect(active!.ratio, const Ratio(investor: 60, manager: 40));
      },
    );

    test('a proposal with a bad date is rejected, not stored', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final approveCreate = await _approveCreate(
        validator,
        manager,
        partnershipId,
      );
      await _receiveInOrder(validator, [approveCreate]);
      final (proposal, _) = await _proposeRatio(
        investor,
        manager,
        partnershipId,
        investorPercent: 50,
        managerPercent: 50,
        effectiveFrom: '01-09-2026',
      );

      expect(
        await validator.receiveText(canonicalJson(proposal.toJson())),
        ReceiveOutcome.rejectedSchema,
      );
      expect(
        (await _activeRatio(validator))!.ratio,
        const Ratio(investor: 60, manager: 40),
      );
    });

    test(
      'a bad date is still ignored by activeRatio if it reaches the '
      'business layer some other way (defense in depth)',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final approveCreate = await _approveCreate(
          validator,
          manager,
          partnershipId,
        );
        await _receiveInOrder(validator, [approveCreate]);

        final (validProposal, validApprove) = await _proposeRatio(
          investor,
          manager,
          partnershipId,
          investorPercent: 50,
          managerPercent: 50,
          effectiveFrom: '2026-09-01',
        );
        final proposal = validProposal.copyWith(
          body: {
            'ratio': {'investor': 50, 'manager': 50},
            'effectiveFrom': '01-09-2026',
          },
        );

        final records = [...validator.usableRecords, proposal, validApprove];
        final effectiveness = computeEffective(
          records,
          partnershipKeys: validator.partnershipKeys!,
        );
        final active = activeRatio(records, effectiveness: effectiveness);

        expect(active!.ratio, const Ratio(investor: 60, manager: 40));
      },
    );

    test(
      'a partnership_create with a bad ratio is refused, so it gives no ratio',
      () async {
        final investor = ChainAuthor(await generateEd25519KeyPair());
        final manager = ChainAuthor(await generateEd25519KeyPair());
        final partnershipId = testId('partnership-bad');
        final validator = Validator.unpinnedForTesting();
        final create = await investor.next(
          partnership: partnershipId,
          type: 'partnership_create',
          id: partnershipId,
          body: {
            'investor': investor.key,
            'manager': manager.key,
            'ratio': {'investor': 70, 'manager': 20},
            'currency': 'PKR',
          },
        );
        final approve = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: create.id,
        );
        // The validator refuses the create (sum is 90, not 100), so it is never
        // stored. Its approve then has no partnership to belong to, and is
        // refused too. No ratio exists at all.
        expect(
          await validator.receiveText(canonicalJson(create.toJson())),
          ReceiveOutcome.rejectedSchema,
        );
        expect(
          await validator.receiveText(canonicalJson(approve.toJson())),
          isNot(ReceiveOutcome.accepted),
        );
        // No partnership was formed, so there are no keys to calculate with.
        expect(validator.partnershipKeys, isNull);
      },
    );

    test(
      'the latest effectiveFrom wins, whatever order the records arrive in',
      () async {
        final (first, investor, manager, partnershipId) =
            await setUpPartnership();
        final create = first.usableRecords.singleWhere(
          (r) => r.type == 'partnership_create',
        );
        final approveCreate = await manager.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: create.id,
        );
        final (early, approveEarly) = await _proposeRatio(
          investor,
          manager,
          partnershipId,
          investorPercent: 30,
          managerPercent: 70,
          effectiveFrom: '2026-11-01',
        );
        final (late, approveLate) = await _proposeRatio(
          investor,
          manager,
          partnershipId,
          investorPercent: 50,
          managerPercent: 50,
          effectiveFrom: '2026-12-01',
        );
        final orders = [
          [approveCreate, early, approveEarly, late, approveLate],
          [approveLate, late, approveEarly, early, approveCreate],
          [late, approveCreate, approveLate, approveEarly, early],
        ];

        for (final order in orders) {
          final validator = Validator.unpinnedForTesting();
          await validator.receiveText(canonicalJson(create.toJson()));
          // Some orders deliver a record before its chain predecessor. Those are
          // held as pending and released later, so only the final state matters.
          for (final record in order) {
            await validator.receiveText(canonicalJson(record.toJson()));
          }

          final active = await _activeRatio(validator);
          expect(active!.ratio, const Ratio(investor: 50, manager: 50));
          expect(active.agreedStart, '2026-12-01');
        }
      },
    );
  });
}
