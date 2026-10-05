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
/// gives the same answer. Closure, domination and emptiness are checked in a
/// later step.
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
