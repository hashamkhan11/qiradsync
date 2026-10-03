import 'record.dart';

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

  const Decision({
    required this.target,
    required this.status,
    required this.firstResponse,
    required this.ignoredResponses,
  });
}

const _needsApproval = {'partnership_create', 'budget_proposal', 'withdraw_request', 'ratio_proposal'};

/// Decides every record in [usable] that needs approval, spec section 5.
///
/// [usable] must already be filtered to records that passed spec section 6.1
/// (see `Validator.usableRecords`). Only the other partner's `approve` or
/// `reject` counts. The first one is the response with the lowest `seq`,
/// not the one that arrived first over the network. Because the other
/// partner is a single author, `seq` alone gives one fixed order everywhere.
List<Decision> decideApprovals(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
}) {
  final records = usable.toList();

  final responsesByTarget = <String, List<Record>>{};
  for (final record in records) {
    final target = record.refersTo;
    if ((record.type == 'approve' || record.type == 'reject') && target != null) {
      responsesByTarget.putIfAbsent(target, () => []).add(record);
    }
  }

  final targets = records.where((r) => _needsApproval.contains(r.type)).toList()
    ..sort((a, b) {
      final byAuthor = a.author.compareTo(b.author);
      return byAuthor != 0 ? byAuthor : a.seq.compareTo(b.seq);
    });

  return [
    for (final target in targets)
      _decide(target, responsesByTarget[target.id] ?? const [], partnershipKeys),
  ];
}

Decision _decide(Record target, List<Record> responses, Set<String> partnershipKeys) {
  // A partner cannot approve or reject their own proposal, so those responses
  // are not counted at all, not even as ignored evidence.
  final counted = responses
      .where((r) => r.author != target.author && partnershipKeys.contains(r.author))
      .toList()
    ..sort((a, b) => a.seq.compareTo(b.seq));

  if (counted.isEmpty) {
    return Decision(
      target: target,
      status: DecisionStatus.pending,
      firstResponse: null,
      ignoredResponses: const [],
    );
  }

  final first = counted.first;
  return Decision(
    target: target,
    status: first.type == 'approve' ? DecisionStatus.active : DecisionStatus.dead,
    firstResponse: first,
    ignoredResponses: counted.sublist(1),
  );
}
