import 'effective.dart';
import 'money.dart';
import 'record.dart';

/// [grantee]'s own effective budgets, each with how much is left (spec
/// section 5, 6.4): `{ "amount": int, "receiptHash": ... }` on `expense` must
/// refer to an approved `budget_proposal` whose `grantee` is the author. A
/// budget can be *proposed* by either partner, but only its grantee may
/// *spend* it.
///
/// This is the one list both sides of an expense use: the form offers it as
/// the choice of budgets to spend from, and
/// `RecordWriter.proposeExpense` checks the chosen budget id is a key of this
/// same map before writing anything (spec 6.1's "the app never writes a
/// record it already knows is invalid").
Map<String, int> effectiveBudgetsFor(
  Iterable<Record> usable, {
  required Set<String> partnershipKeys,
  required String grantee,
}) {
  final records = usable.toList();
  final effectiveness = computeEffective(
    records,
    partnershipKeys: partnershipKeys,
  );
  final money = computeMoney(records, effectiveness: effectiveness);
  final byId = {for (final r in records) r.id: r};

  return {
    for (final entry in money.budgetLeft.entries)
      if (byId[entry.key]?.body['grantee'] == grantee) entry.key: entry.value,
  };
}
