import 'record.dart';

/// The record type that closes a period of the ledger (spec section 6.7).
const settlementType = 'settlement';

/// The two partners by role, read from the approved `partnership_create`.
///
/// Settlement needs the roles, not just the set of keys, because only the
/// manager may write a settlement and only the investor may answer it.
class Parties {
  final String investor;
  final String manager;

  const Parties({required this.investor, required this.manager});
}

/// The roles from the partnership's create record, or `null` if no create is
/// held yet. A ledger holds one partnership, so there is one create.
Parties? partiesOf(Iterable<Record> records) {
  for (final record in records) {
    if (record.type != 'partnership_create') continue;
    final investor = record.body['investor'];
    final manager = record.body['manager'];
    if (investor is String && manager is String) {
      return Parties(investor: investor, manager: manager);
    }
  }
  return null;
}

/// The cut of a well-formed settlement, or `null` if [record] is not one.
///
/// Step 4a rules from spec section 6.7:
/// 1. Only the manager writes a settlement. A settlement by the investor is
///    not a proposal at all. It is stored as evidence and never takes effect.
/// 2. It has no `refersTo`.
/// 3. The cut names exactly the two partners' keys, each with a whole number
///    of zero or more.
/// 4. The manager's value is lower than the settlement's own `seq`, so a
///    settlement never covers itself.
///
/// These checks use only the record and the partners' roles, so every device
/// gives the same answer. The checks that need the records themselves are in
/// [cutIsHeld] and [cutProblem].
Map<String, int>? settlementCut(Record record, Parties parties) {
  if (record.type != settlementType) return null;
  if (record.author != parties.manager) return null;
  if (record.refersTo != null) return null;

  final cut = record.body['cut'];
  if (cut is! Map || cut.length != 2) return null;

  final investorValue = cut[parties.investor];
  final managerValue = cut[parties.manager];
  if (investorValue is! int || managerValue is! int) return null;
  if (investorValue < 0 || managerValue < 0) return null;
  if (managerValue >= record.seq) return null;

  return {parties.investor: investorValue, parties.manager: managerValue};
}

/// True when the phone holds every record that the [cut] covers (spec 6.7).
///
/// Chains have no gaps (spec 7.1). So holding the record at seq `v` for a
/// partner means holding all of that partner's records up to `v`. A cut with
/// a value of 0 covers nothing from that partner.
bool cutIsHeld(Iterable<Record> records, Map<String, int> cut) {
  for (final entry in cut.entries) {
    if (entry.value == 0) continue;
    final held = records.any(
      (r) => r.author == entry.key && r.seq == entry.value,
    );
    if (!held) return false;
  }
  return true;
}

/// The first reason the [cut] fails a check, or `null` if it passes (spec 6.7,
/// cut rules 3 to 5). Only call this when [cutIsHeld] is true.
///
/// Why the answer is final: when the phone holds the whole cut, every record
/// inside the cut is known. A record that is not held is outside the cut, by
/// definition. So a check that fails now can never pass after more records
/// arrive.
///
/// - Closed (rule 3): a record inside the cut that refers to another record
///   must refer to one inside the cut. Decisions are not checked here. An
///   undecided request inside a cut has no effect in that period, and its
///   approval counts in the period where the approval falls (spec 6.7).
/// - Dominating (rule 4): each value is at least the previous effective cut's.
/// - Not empty (rule 5): at least one value is larger than the previous cut's.
String? cutProblem(
  Iterable<Record> records,
  Parties parties,
  Map<String, int> cut,
  Map<String, int> previous,
) {
  final byId = {for (final r in records) r.id: r};

  for (final record in records) {
    final limit = cut[record.author];
    // Records outside the cut have no say in whether the cut is closed.
    if (limit == null || record.seq > limit) continue;
    final targetId = record.refersTo;
    if (targetId == null) continue;

    final target = byId[targetId];
    final inside = target != null && target.seq <= (cut[target.author] ?? -1);
    if (!inside) return 'refers to a record outside the cut';
  }

  for (final key in [parties.investor, parties.manager]) {
    if (cut[key]! < previous[key]!) return 'does not cover the previous cut';
  }

  final grows = [
    parties.investor,
    parties.manager,
  ].any((key) => cut[key]! > previous[key]!);
  if (!grows) return 'covers nothing new';

  return null;
}
