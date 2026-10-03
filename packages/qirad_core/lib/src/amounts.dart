import 'record.dart';

/// The integer amount in `body['amount']`, or `null` if it is not a positive
/// integer. Money is always an integer in paisa (hard rule 1), so a double is
/// rejected here even though canonical JSON should never let one through.
int? positiveAmount(Record record) {
  final amount = record.body['amount'];
  if (amount is! int || amount <= 0) return null;
  return amount;
}
