/// Shows an amount in paisa as rupees, for example 120000 -> "Rs 1,200.00".
///
/// Money is an integer in paisa everywhere (hard rule 1). Only this function
/// turns it into text, so no screen does its own rounding.
String formatPaisa(int paisa) {
  final sign = paisa < 0 ? '-' : '';
  final absolute = paisa.abs();
  final rupees = _groupThousands(absolute ~/ 100);
  final paise = (absolute % 100).toString().padLeft(2, '0');
  return '${sign}Rs $rupees.$paise';
}

String _groupThousands(int value) {
  final digits = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final left = digits.length - i;
    if (i > 0 && left % 3 == 0) buffer.write(',');
    buffer.write(digits[i]);
  }
  return buffer.toString();
}

/// The local calendar day as `YYYY-MM-DD`. It is shown as a label and passed
/// to the ratio lookup. It is never stored or used to order records.
String localDateLabel(DateTime now) {
  final year = now.year.toString().padLeft(4, '0');
  final month = now.month.toString().padLeft(2, '0');
  final day = now.day.toString().padLeft(2, '0');
  return '$year-$month-$day';
}
