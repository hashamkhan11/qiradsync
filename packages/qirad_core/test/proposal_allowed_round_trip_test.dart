import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

/// One record type's allowed-proposal case: the extra [proposalRefusal]
/// parameters it needs, and the body [RecordWriter] (apps/mobile) would
/// build for it once [proposalRefusal] allows it.
///
/// This guards the whole class of "writer creates a record the validator
/// rejects" bugs (the bug this fix started from, for `nonPositiveAmount`,
/// was exactly this): a mismatch between what [proposalRefusal] calls
/// allowed and what [Validator] accepts on receipt would show up here for
/// every type, not just the one that was actually caught.
void main() {
  group(
    'every type proposalRefusal allows, the validator accepts (spec '
    'section 5)',
    () {
      test('invest', () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        expect(
          proposalRefusal(
            type: 'invest',
            author: investor.key,
            parties: parties,
            ledger: validator.usableRecords.toList(),
            validator: validator,
            amount: 1000,
          ),
          isNull,
        );

        final record = await investor.next(
          partnership: partnership,
          type: 'invest',
          body: {'amount': 1000},
        );
        expect(
          await validator.receiveText(canonicalJson(record.toJson())),
          ReceiveOutcome.accepted,
        );
      });

      test('sale', () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        expect(
          proposalRefusal(
            type: 'sale',
            author: manager.key,
            parties: parties,
            ledger: validator.usableRecords.toList(),
            validator: validator,
            amount: 1000,
          ),
          isNull,
        );

        final record = await manager.next(
          partnership: partnership,
          type: 'sale',
          body: {'amount': 1000},
        );
        expect(
          await validator.receiveText(canonicalJson(record.toJson())),
          ReceiveOutcome.accepted,
        );
      });

      test('budget_proposal', () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        expect(
          proposalRefusal(
            type: 'budget_proposal',
            author: investor.key,
            parties: parties,
            ledger: validator.usableRecords.toList(),
            validator: validator,
            amount: 1000,
          ),
          isNull,
        );

        final record = await investor.next(
          partnership: partnership,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 1000},
        );
        expect(
          await validator.receiveText(canonicalJson(record.toJson())),
          ReceiveOutcome.accepted,
        );
      });

      test('expense', () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        final budget = await investor.next(
          partnership: partnership,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 5000},
        );
        final approve = await manager.next(
          partnership: partnership,
          type: 'approve',
          refersTo: budget.id,
        );
        await validator.receiveText(canonicalJson(budget.toJson()));
        await validator.receiveText(canonicalJson(approve.toJson()));

        expect(
          proposalRefusal(
            type: 'expense',
            author: manager.key,
            parties: parties,
            ledger: validator.usableRecords.toList(),
            validator: validator,
            budgetId: budget.id,
            amount: 2000,
          ),
          isNull,
        );

        final record = await manager.next(
          partnership: partnership,
          type: 'expense',
          refersTo: budget.id,
          body: const {'amount': 2000},
        );
        expect(
          await validator.receiveText(canonicalJson(record.toJson())),
          ReceiveOutcome.accepted,
        );
      });

      test('withdraw_request (capital)', () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        final invest = await investor.next(
          partnership: partnership,
          type: 'invest',
          body: {'amount': 1000},
        );
        await validator.receiveText(canonicalJson(invest.toJson()));

        expect(
          proposalRefusal(
            type: 'withdraw_request',
            author: investor.key,
            parties: parties,
            ledger: validator.usableRecords.toList(),
            validator: validator,
            kind: 'capital',
            amount: 500,
          ),
          isNull,
        );

        final record = await investor.next(
          partnership: partnership,
          type: 'withdraw_request',
          body: const {'amount': 500, 'kind': 'capital'},
        );
        expect(
          await validator.receiveText(canonicalJson(record.toJson())),
          ReceiveOutcome.accepted,
        );
      });

      test('withdraw_request (profit)', () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        expect(
          proposalRefusal(
            type: 'withdraw_request',
            author: manager.key,
            parties: parties,
            ledger: validator.usableRecords.toList(),
            validator: validator,
            kind: 'profit',
            amount: 500,
          ),
          isNull,
        );

        final record = await manager.next(
          partnership: partnership,
          type: 'withdraw_request',
          body: const {'amount': 500, 'kind': 'profit'},
        );
        expect(
          await validator.receiveText(canonicalJson(record.toJson())),
          ReceiveOutcome.accepted,
        );
      });

      test('ratio_proposal', () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        expect(
          proposalRefusal(
            type: 'ratio_proposal',
            author: investor.key,
            parties: parties,
            ledger: validator.usableRecords.toList(),
            validator: validator,
          ),
          isNull,
        );

        final record = await investor.next(
          partnership: partnership,
          type: 'ratio_proposal',
          body: const {
            'ratio': {'investor': 70, 'manager': 30},
            'effectiveFrom': '2026-01-01',
          },
        );
        expect(
          await validator.receiveText(canonicalJson(record.toJson())),
          ReceiveOutcome.accepted,
        );
      });

      test('reversal', () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        final invest = await investor.next(
          partnership: partnership,
          type: 'invest',
          body: {'amount': 1000},
        );
        await validator.receiveText(canonicalJson(invest.toJson()));

        expect(
          proposalRefusal(
            type: 'reversal',
            author: manager.key,
            parties: parties,
            ledger: validator.usableRecords.toList(),
            validator: validator,
            reversalTarget: invest.id,
          ),
          isNull,
        );

        final record = await manager.next(
          partnership: partnership,
          type: 'reversal',
          refersTo: invest.id,
        );
        expect(
          await validator.receiveText(canonicalJson(record.toJson())),
          ReceiveOutcome.accepted,
        );
      });

      test('settlement', () async {
        final (validator, investor, manager, partnership) =
            await setUpPartnership();
        final parties = Parties(investor: investor.key, manager: manager.key);

        expect(
          proposalRefusal(
            type: 'settlement',
            author: manager.key,
            parties: parties,
            ledger: validator.usableRecords.toList(),
            validator: validator,
          ),
          isNull,
        );

        // The cut RecordWriter.proposeSettlement builds: each partner's
        // highest seq currently held (spec 6.7).
        final cut = periodShares(
          validator.usableRecords,
          partnershipKeys: validator.partnershipKeys!,
        ).last.closingCut;

        final record = await manager.next(
          partnership: partnership,
          type: 'settlement',
          body: {'cut': cut},
        );
        expect(
          await validator.receiveText(canonicalJson(record.toJson())),
          ReceiveOutcome.accepted,
        );
      });
    },
  );
}
