import 'approvals.dart';
import 'effective.dart';
import 'record.dart';
import 'settlement.dart';
import 'settlement_states.dart';

/// The kinds of pending item the inbox can show (spec sections 5 and 6.7).
enum InboxKind {
  settlement,
  withdrawal,
  budget,
  ratio,
  partnershipStart,
  reversal,
}

/// One record that waits for this partner's answer.
class InboxItem {
  final Record target;
  final InboxKind kind;

  /// False when this partner cannot approve yet, or ever. Reject is always
  /// allowed, so the screen keeps the reject button in every case.
  final bool canApprove;

  /// Why approve is not allowed, or `null` when it is allowed. Shown to the
  /// partner in plain words.
  final String? blockedReason;

  const InboxItem({
    required this.target,
    required this.kind,
    required this.canApprove,
    required this.blockedReason,
  });
}

/// The items waiting for [myKey]'s answer, in a fixed order (author, then seq).
///
/// Why this is a pure function of the records: the same usable records give the
/// same list on every phone. A record is listed only when it is still pending
/// and its author is the other partner. A partner never answers their own
/// record, so those are never listed.
///
/// [usable] must already be filtered by `Validator.usableRecords`.
List<InboxItem> approvalsInbox(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
  required String myKey,
}) {
  // A phone that is not a partner has no inbox.
  if (!partnershipKeys.contains(myKey)) return const [];

  final records = usable.toList();
  final decisions = decideApprovals(records, partnershipKeys: partnershipKeys);
  final parties = partiesOf(records);
  final settlements = parties == null
      ? <SettlementStatus>[]
      : settlementStatuses(records, parties: parties, decisions: decisions);

  // A partner can reverse their own still-pending record at any time, with no
  // approval needed (spec section 5). Once that reversal is effective, the
  // original request is gone from both sides, so the other partner must stop
  // seeing it as something to answer.
  final effectiveness = computeEffective(
    records,
    partnershipKeys: partnershipKeys,
  );

  final items = <InboxItem>[];
  for (final decision in decisions) {
    final target = decision.target;
    if (decision.status != DecisionStatus.pending) continue;
    if (target.author == myKey) continue;
    if (effectiveness.cancelledIds.contains(target.id)) continue;

    final kind = _kindOf(target);
    if (kind == InboxKind.settlement) {
      final blocked = _settlementBlock(
        target,
        records: records,
        myKey: myKey,
        settlements: settlements,
      );
      items.add(
        InboxItem(
          target: target,
          kind: kind,
          canApprove: blocked == null,
          blockedReason: blocked,
        ),
      );
    } else {
      items.add(
        InboxItem(
          target: target,
          kind: kind,
          canApprove: true,
          blockedReason: null,
        ),
      );
    }
  }

  items.sort((a, b) {
    final byAuthor = a.target.author.compareTo(b.target.author);
    return byAuthor != 0 ? byAuthor : a.target.seq.compareTo(b.target.seq);
  });
  return items;
}

InboxKind _kindOf(Record target) {
  switch (target.type) {
    case 'settlement':
      return InboxKind.settlement;
    case 'withdraw_request':
      return InboxKind.withdrawal;
    case 'budget_proposal':
      return InboxKind.budget;
    case 'ratio_proposal':
      return InboxKind.ratio;
    case 'partnership_create':
      return InboxKind.partnershipStart;
    default:
      return InboxKind.reversal;
  }
}

/// Why the investor cannot approve this settlement yet, or `null` when approve
/// is allowed. Only the investor answers a settlement, so [myKey] is the
/// investor here.
///
/// The three checks run in this order, so each partner sees the first problem:
/// 1. An earlier proposal is still waiting. The ordering rule (spec 6.7) makes
///    any approve of this one invalid until the earlier one is answered.
/// 2. The cut names an investor record the investor has not written. The
///    investor's own approve gets the next free seq, so a cut value at or above
///    that seq can never be approved. This is final, not a sync delay.
/// 3. The phone does not hold the whole cut yet. This may clear after sync.
String? _settlementBlock(
  Record target, {
  required List<Record> records,
  required String myKey,
  required List<SettlementStatus> settlements,
}) {
  // A malformed settlement is not in the proposal list, so it has no cut and
  // no approve can count for it.
  final index = settlements.indexWhere((s) => s.record.id == target.id);
  if (index < 0) return 'Not a valid settlement. Reject it.';

  if (index > 0 &&
      settlements.take(index).any((s) => s.state == SettlementState.waiting)) {
    return 'Answer the earlier settlement first.';
  }

  final cut = settlements[index].cut;
  final nextSeq = _nextSeqFor(records, myKey);
  if (cut[myKey]! >= nextSeq) {
    return 'Covers investor records that do not exist. Reject it.';
  }

  if (!cutIsHeld(records, cut)) {
    return 'Waiting for records to sync.';
  }
  return null;
}

/// The seq of this partner's next record: one more than the highest seq held.
int _nextSeqFor(List<Record> records, String myKey) {
  var highest = 0;
  for (final record in records) {
    if (record.author == myKey && record.seq > highest) highest = record.seq;
  }
  return highest + 1;
}
