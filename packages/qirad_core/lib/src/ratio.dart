import 'record.dart';

/// The profit split between the partners, as whole percentages (spec 6.6).
/// The two values always add up to 100.
class Ratio {
  final int investor;
  final int manager;

  const Ratio({required this.investor, required this.manager});

  @override
  bool operator ==(Object other) =>
      other is Ratio && other.investor == investor && other.manager == manager;

  @override
  int get hashCode => Object.hash(investor, manager);

  @override
  String toString() => 'investor $investor : manager $manager';
}

/// Reads `body['ratio']` as `{"investor": int, "manager": int}`. Returns `null`
/// unless both are non-negative integers that add up to 100.
Ratio? ratioOf(Record record) {
  final raw = record.body['ratio'];
  if (raw is! Map) return null;

  final investor = raw['investor'];
  final manager = raw['manager'];
  if (investor is! int || manager is! int) return null;
  if (investor < 0 || manager < 0 || investor + manager != 100) return null;

  return Ratio(investor: investor, manager: manager);
}

/// True for a real calendar date written as `YYYY-MM-DD`. The format makes
/// text order the same as date order, which the active ratio relies on.
bool isIsoDate(Object? value) {
  if (value is! String) return false;
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  return DateTime.tryParse(value) != null;
}
