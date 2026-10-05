import 'package:qirad_core/qirad_core.dart';

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

/// The ratio as text, for example "50/50 (agreed to start 2026-11-01)". The
/// date is only text. Nothing is decided from it (hard rule 3).
String formatRatio(ActiveRatio active) {
  final ratio = '${active.ratio.investor}/${active.ratio.manager}';
  final start = active.agreedStart;
  return start == null
      ? '$ratio (from the start)'
      : '$ratio (agreed to start $start)';
}
