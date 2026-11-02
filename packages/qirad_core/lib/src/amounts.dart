import 'record.dart';

/// True when [value] is a positive integer. Money is always an integer in
/// paisa (hard rule 1), so a double is rejected here even though canonical
/// JSON should never let one through. This is the one rule for "is this
/// amount usable" — [positiveAmount] below applies it to a stored record's
/// body, and the writer and the create forms apply it to a raw input before
/// any record exists, so a zero or negative amount is refused in the same
/// way everywhere instead of each caller re-deriving the bound.
bool isPositiveAmount(Object? value) => value is int && value > 0;

/// The integer amount in `body['amount']`, or `null` if it is not positive.
int? positiveAmount(Record record) {
  final amount = record.body['amount'];
  return isPositiveAmount(amount) ? amount as int : null;
}
