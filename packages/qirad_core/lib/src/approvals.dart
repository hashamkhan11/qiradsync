import 'record.dart';
import 'settlement.dart';

/// Where a record that needs approval stands, spec section 5.
/// Moves from pending to active or dead, and never moves back.
enum DecisionStatus { pending, active, dead }

/// The approval decision for one target record.
class Decision {
  final Record target;
  final DecisionStatus status;

  /// The response that decided the target, or null while still pending.
  final Record? firstResponse;

  /// Later responses from the same partner. Kept as evidence, ignored in
  /// every calculation (the UI shows them as "ignored: later response").
  final List<Record> ignoredResponses;

  /// Responses that break the settlement ordering rule (spec 6.7). They are
  /// kept as evidence and never decide anything. Empty for every other type.
  final List<Record> invalidResponses;

  const Decision({
    required this.target,
    required this.status,
    required this.firstResponse,
    required this.ignoredResponses,
    this.invalidResponses = const [],
  });

  /// True when [author] has at least one valid response to this target. An
  /// invalid response does not count, so it does not stop the author from
  /// answering again later (spec 6.7). A writer uses this to refuse a second
  /// valid answer, and allow a new one after an invalid answer.
  bool hasValidResponseFrom(String author) =>
      firstResponse?.author == author ||
      ignoredResponses.any((r) => r.author == author);
}

const _needsApproval = {
  'partnership_create',
  'budget_proposal',
  'withdraw_request',
  'ratio_proposal',
  'settlement',
};

/// Decides every record in [usable] that needs approval, spec section 5.
///
/// [usable] must already be filtered to records that passed spec section 6.1
/// (see `Validator.usableRecords`). Only the other partner's `approve` or
/// `reject` counts. Of those, invalid ones never count (see below). The first
/// valid one is the response with the lowest `seq`, not the one that arrived
/// first over the network. Because the other partner is a single author, `seq`
/// alone gives one fixed order everywhere.
///
/// A `reversal` needs approval only when it cancels the other partner's
/// record. A reversal whose target is missing is not decided yet, because
/// its target may still arrive.
///
/// Settlement proposals (spec 6.7) have one more rule. The investor's answer
/// to settlement S_k is valid only if the investor already answered every
/// earlier proposal, at a lower investor `seq`. Other responses are kept on
/// the decision as `invalidResponses` and never count.
List<Decision> decideApprovals(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
}) {
  final records = usable.toList();

  final byId = {for (final r in records) r.id: r};

  final responsesByTarget = <String, List<Record>>{};
  for (final record in records) {
    final target = record.refersTo;
    if ((record.type == 'approve' || record.type == 'reject') &&
        target != null) {
      responsesByTarget.putIfAbsent(target, () => []).add(record);
    }
  }

  bool needsApproval(Record record) {
    if (_needsApproval.contains(record.type)) return true;
    if (record.type != 'reversal' || record.refersTo == null) return false;
    final target = byId[record.refersTo];
    return target != null && target.author != record.author;
  }

  final targets = records.where(needsApproval).toList()
    ..sort((a, b) {
      final byAuthor = a.author.compareTo(b.author);
      return byAuthor != 0 ? byAuthor : a.seq.compareTo(b.seq);
    });

  // The settlement proposals, in the manager's seq order. Only well-formed
  // ones take part in the ordering rule, so a malformed record can never block
  // the next settlement.
  final parties = partiesOf(records);
  final proposals = parties == null
      ? <Record>[]
      : (records.where((r) => settlementCut(r, parties) != null).toList()
          ..sort((a, b) => a.seq.compareTo(b.seq)));

  final validByProposal = <String, List<Record>>{};
  final invalidByProposal = <String, List<Record>>{};
  for (var k = 0; k < proposals.length; k++) {
    final proposal = proposals[k];
    final counted = _counted(
      proposal,
      responsesByTarget[proposal.id] ?? const [],
      partnershipKeys,
    );
    final cut = settlementCut(proposal, parties!)!;
    final valid = <Record>[];
    final invalid = <Record>[];
    for (final response in counted) {
      // Chains have no gaps, so every earlier proposal is already known here.
      final answeredEarlier = proposals
          .take(k)
          .every(
            (earlier) => (validByProposal[earlier.id] ?? const []).any(
              (answer) => answer.seq < response.seq,
            ),
          );
      final namesFuture = approveNamesFutureRecords(response, cut, parties);
      (answeredEarlier && !namesFuture ? valid : invalid).add(response);
    }
    validByProposal[proposal.id] = valid;
    invalidByProposal[proposal.id] = invalid;
  }

  return [
    for (final target in targets)
      if (validByProposal.containsKey(target.id))
        _decide(
          target,
          validByProposal[target.id]!,
          invalidByProposal[target.id]!,
        )
      else
        _decide(
          target,
          _counted(
            target,
            responsesByTarget[target.id] ?? const [],
            partnershipKeys,
          ),
          const [],
        ),
  ];
}

/// The responses that count for [target]: the other partner's, sorted by seq.
/// A partner cannot approve or reject their own proposal, so those responses
/// are not counted at all, not even as ignored evidence.
List<Record> _counted(
  Record target,
  List<Record> responses,
  Set<String> partnershipKeys,
) {
  return responses
      .where(
        (r) => r.author != target.author && partnershipKeys.contains(r.author),
      )
      .toList()
    ..sort((a, b) => a.seq.compareTo(b.seq));
}

Decision _decide(Record target, List<Record> counted, List<Record> invalid) {
  if (counted.isEmpty) {
    return Decision(
      target: target,
      status: DecisionStatus.pending,
      firstResponse: null,
      ignoredResponses: const [],
      invalidResponses: invalid,
    );
  }

  final first = counted.first;
  return Decision(
    target: target,
    status: first.type == 'approve'
        ? DecisionStatus.active
        : DecisionStatus.dead,
    firstResponse: first,
    ignoredResponses: counted.sublist(1),
    invalidResponses: invalid,
  );
}
