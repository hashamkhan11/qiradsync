import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

/// Hand-built records for the rules that the approve rule makes redundant at
/// system level. Nothing here is signed: `cutIsHeld` and `settlementStatuses`
/// read only the fields, so these tests can build exactly the state they need.
const _investor = 'investor-key';
const _manager = 'manager-key';
const _parties = Parties(investor: _investor, manager: _manager);

Record _record({
  required String id,
  required String author,
  required int seq,
  required String type,
  Map<String, dynamic> body = const {},
}) => Record(
  v: 1,
  id: id,
  partnership: 'partnership-unit',
  author: author,
  seq: seq,
  prevHash: '0' * 64,
  type: type,
  body: body,
  refersTo: null,
  note: '',
  time: '2026-10-06T10:00:00Z',
  sig: '',
);

Record _settlement({
  required String id,
  required int seq,
  required int investorValue,
  required int managerValue,
}) => _record(
  id: id,
  author: _manager,
  seq: seq,
  type: settlementType,
  body: {
    'cut': {_investor: investorValue, _manager: managerValue},
  },
);

Decision _decision(Record target, DecisionStatus status) => Decision(
  target: target,
  status: status,
  firstResponse: null,
  ignoredResponses: const [],
);

/// Looks up the state of one proposal in the result of [settlementStatuses].
SettlementState _stateOf(List<SettlementStatus> statuses, String id) =>
    statuses.singleWhere((s) => s.record.id == id).state;

void main() {
  group('cutIsHeld (spec 6.7, cut held rule)', () {
    test('a cut of zero for both partners needs no records', () {
      expect(cutIsHeld(const [], {_investor: 0, _manager: 0}), isTrue);
    });

    test('a cut is held when every non-zero value has its record', () {
      final records = [
        _record(id: 'i1', author: _investor, seq: 1, type: 'invest'),
        _record(id: 'm1', author: _manager, seq: 1, type: 'sale'),
        _record(id: 'm2', author: _manager, seq: 2, type: 'sale'),
      ];
      expect(cutIsHeld(records, {_investor: 1, _manager: 2}), isTrue);
    });

    test('a manager value with a missing record in the chain is not held', () {
      // The manager's seq 2 is missing, so the cut is not held. Seq 1 alone is
      // not enough: the cut names seq 2 itself, and chains have no gaps.
      final records = [
        _record(id: 'i1', author: _investor, seq: 1, type: 'invest'),
        _record(id: 'm1', author: _manager, seq: 1, type: 'sale'),
      ];
      expect(cutIsHeld(records, {_investor: 1, _manager: 2}), isFalse);
    });

    test('a record with the right seq but the other author does not count', () {
      // Investor seq 1 is held, but the cut names manager seq 1 and the only
      // seq 1 record belongs to the investor.
      final records = [
        _record(id: 'i1', author: _investor, seq: 1, type: 'invest'),
      ];
      expect(cutIsHeld(records, {_investor: 1, _manager: 1}), isFalse);
    });
  });

  group('chained rule (spec 6.7, one waiting proposal blocks later ones)', () {
    // Manager seq 1 and 2 are sales, seq 3 and 4 are settlements. The cuts
    // are valid on their own: S1 covers manager 1, S2 covers manager 2.
    final investorInvest = _record(
      id: 'i1',
      author: _investor,
      seq: 1,
      type: 'invest',
    );
    final sale1 = _record(id: 'm1', author: _manager, seq: 1, type: 'sale');
    final sale2 = _record(id: 'm2', author: _manager, seq: 2, type: 'sale');
    final s1 = _settlement(id: 's1', seq: 3, investorValue: 1, managerValue: 1);
    final s2 = _settlement(id: 's2', seq: 4, investorValue: 1, managerValue: 2);
    final records = [investorInvest, sale1, sale2, s1, s2];

    test('a pending S1 keeps a later active S2 waiting', () {
      // S1 has no decision (pending), so it is waiting and blocks S2. S2 is
      // active with a valid, held cut, but must not become effective.
      final statuses = settlementStatuses(
        records,
        parties: _parties,
        decisions: [_decision(s2, DecisionStatus.active)],
      );
      expect(_stateOf(statuses, 's1'), SettlementState.waiting);
      expect(_stateOf(statuses, 's2'), SettlementState.waiting);
    });

    test('a rejected S1 does not block a later active S2', () {
      // A rejected proposal is done, so it must not block the next one.
      final statuses = settlementStatuses(
        records,
        parties: _parties,
        decisions: [
          _decision(s1, DecisionStatus.dead),
          _decision(s2, DecisionStatus.active),
        ],
      );
      expect(_stateOf(statuses, 's1'), SettlementState.rejected);
      expect(_stateOf(statuses, 's2'), SettlementState.effective);
    });

    test('an active S1 does not block a later pending S2', () {
      final statuses = settlementStatuses(
        records,
        parties: _parties,
        decisions: [_decision(s1, DecisionStatus.active)],
      );
      expect(_stateOf(statuses, 's1'), SettlementState.effective);
      expect(_stateOf(statuses, 's2'), SettlementState.waiting);
    });
  });

  group('cut held check inside settlementStatuses (spec 6.7)', () {
    test('an active settlement whose cut is not held stays waiting', () {
      // The cut names manager seq 2, but the phone has only the settlement. The
      // cut is not held, so the cut checks never run and it is not effective.
      final s1 = _settlement(
        id: 's1',
        seq: 3,
        investorValue: 1,
        managerValue: 2,
      );
      final statuses = settlementStatuses(
        [_record(id: 'i1', author: _investor, seq: 1, type: 'invest'), s1],
        parties: _parties,
        decisions: [_decision(s1, DecisionStatus.active)],
      );
      expect(_stateOf(statuses, 's1'), SettlementState.waiting);
    });
  });
}
