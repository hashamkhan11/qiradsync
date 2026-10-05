import 'approvals.dart';
import 'record.dart';
import 'settlement.dart';

/// Where one settlement proposal stands, spec section 6.7.
enum SettlementState {
  /// Not decided yet. Either it has no valid answer from the investor, or an
  /// earlier proposal is still waiting. Waiting blocks every later proposal.
  waiting,

  /// Approved and passes the cut checks. Its cut is the new effective cut.
  effective,

  /// The investor rejected it. Done, so it does not block later proposals.
  rejected,

  /// Approved, but a cut check failed. The phone holds the whole cut, so this
  /// is final. Done, so it does not block later proposals.
  invalid,
}

/// The state of one settlement proposal, with its cut and the reason it is
/// invalid, if it is.
class SettlementStatus {
  final Record record;
  final Map<String, int> cut;
  final SettlementState state;

  /// Why the proposal is invalid, or `null` when it is not.
  final String? reason;

  const SettlementStatus({
    required this.record,
    required this.cut,
    required this.state,
    required this.reason,
  });
}

/// The state of every settlement proposal, in the manager's seq order.
///
/// [records] and [decisions] must come from the same usable set.
///
/// Why this is order-based and final:
/// - Proposals are decided in order (spec 6.7). A proposal that is still
///   waiting blocks the ones after it, so an effective cut is always checked
///   against a fixed previous cut.
/// - An approved proposal always has its whole cut held. The investor can only
///   approve after the proposal exists, and any investor record the manager
///   had when writing the cut was written before the approval. So the cut
///   check gives a final answer straight away.
/// - A proposal that fails a check is `invalid`, which counts as done. One
///   broken settlement therefore cannot block every later one.
List<SettlementStatus> settlementStatuses(
  Iterable<Record> records, {
  required Parties parties,
  required List<Decision> decisions,
}) {
  final held = records.toList();
  final decisionById = {for (final d in decisions) d.target.id: d};

  final proposals =
      held.where((r) => settlementCut(r, parties) != null).toList()
        ..sort((a, b) => a.seq.compareTo(b.seq));

  var previous = {parties.investor: 0, parties.manager: 0};
  var blocked = false;
  final statuses = <SettlementStatus>[];

  for (final proposal in proposals) {
    final cut = settlementCut(proposal, parties)!;
    final status = decisionById[proposal.id]?.status ?? DecisionStatus.pending;

    var state = SettlementState.waiting;
    String? reason;

    if (status == DecisionStatus.dead) {
      state = SettlementState.rejected;
    } else if (status == DecisionStatus.active && !blocked) {
      if (cutIsHeld(held, cut)) {
        reason = cutProblem(held, parties, cut, previous);
        if (reason == null) {
          state = SettlementState.effective;
          previous = cut;
        } else {
          state = SettlementState.invalid;
        }
      }
    }

    if (state == SettlementState.waiting) blocked = true;
    statuses.add(
      SettlementStatus(
        record: proposal,
        cut: cut,
        state: state,
        reason: reason,
      ),
    );
  }

  return statuses;
}
