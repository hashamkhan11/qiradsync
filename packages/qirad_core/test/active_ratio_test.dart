import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

Future<Ratio?> _ratioOn(Validator validator, String date) async {
  final effectiveness = computeEffective(
    validator.usableRecords,
    partnershipKeys: validator.partnershipKeys!,
  );
  return activeRatio(
    validator.usableRecords,
    effectiveness: effectiveness,
    date: date,
  );
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

void main() {
  group('active ratio (spec section 6.6)', () {
    test('no ratio while the partnership is not approved', () async {
      final (validator, _, _, _) = await setUpPartnership();

      expect(await _ratioOn(validator, '2026-10-03'), isNull);
    });

    test('the approved partnership_create gives the starting ratio', () async {
      final (validator, _, manager, partnershipId) = await setUpPartnership();
      final create = validator.usableRecords.singleWhere(
        (r) => r.type == 'partnership_create',
      );
      final approve = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: create.id,
      );
      await _receiveInOrder(validator, [approve]);

      final ratio = await _ratioOn(validator, '2026-10-03');

      expect(ratio, const Ratio(investor: 60, manager: 40));
    });

    test('a proposal applies only from its effectiveFrom date', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final create = validator.usableRecords.singleWhere(
        (r) => r.type == 'partnership_create',
      );
      final approveCreate = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: create.id,
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

      expect(
        await _ratioOn(validator, '2026-10-31'),
        const Ratio(investor: 60, manager: 40),
      );
      expect(
        await _ratioOn(validator, '2026-11-01'),
        const Ratio(investor: 50, manager: 50),
      );
    });

    test('a proposal that is not approved does not change the ratio', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final create = validator.usableRecords.singleWhere(
        (r) => r.type == 'partnership_create',
      );
      final approveCreate = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: create.id,
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
        await _ratioOn(validator, '2026-10-03'),
        const Ratio(investor: 60, manager: 40),
      );
    });

    test('a proposal whose ratio does not add up to 100 is ignored', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final create = validator.usableRecords.singleWhere(
        (r) => r.type == 'partnership_create',
      );
      final approveCreate = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: create.id,
      );
      final (proposal, approve) = await _proposeRatio(
        investor,
        manager,
        partnershipId,
        investorPercent: 90,
        managerPercent: 20,
        effectiveFrom: '2026-09-01',
      );
      await _receiveInOrder(validator, [approveCreate, proposal, approve]);

      expect(
        await _ratioOn(validator, '2026-10-03'),
        const Ratio(investor: 60, manager: 40),
      );
    });

    test('a proposal with a bad date is ignored', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final create = validator.usableRecords.singleWhere(
        (r) => r.type == 'partnership_create',
      );
      final approveCreate = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: create.id,
      );
      final (proposal, approve) = await _proposeRatio(
        investor,
        manager,
        partnershipId,
        investorPercent: 50,
        managerPercent: 50,
        effectiveFrom: '01-09-2026',
      );
      await _receiveInOrder(validator, [approveCreate, proposal, approve]);

      expect(
        await _ratioOn(validator, '2026-10-03'),
        const Ratio(investor: 60, manager: 40),
      );
    });

    test('a partnership_create with a bad ratio gives no ratio', () async {
      final investor = ChainAuthor(await generateEd25519KeyPair());
      final manager = ChainAuthor(await generateEd25519KeyPair());
      const partnershipId = 'partnership-bad';
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
      await _receiveInOrder(validator, [create, approve]);

      expect(await _ratioOn(validator, '2026-10-03'), isNull);
    });

    test('a date that is not YYYY-MM-DD is rejected', () async {
      final (validator, _, _, _) = await setUpPartnership();
      final effectiveness = computeEffective(
        validator.usableRecords,
        partnershipKeys: validator.partnershipKeys!,
      );

      expect(
        () => activeRatio(
          validator.usableRecords,
          effectiveness: effectiveness,
          date: '3/10/2026',
        ),
        throwsArgumentError,
      );
    });

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

          expect(
            await _ratioOn(validator, '2026-11-15'),
            const Ratio(investor: 30, manager: 70),
          );
          expect(
            await _ratioOn(validator, '2026-12-31'),
            const Ratio(investor: 50, manager: 50),
          );
        }
      },
    );
  });
}
