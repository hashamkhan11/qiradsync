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

/// Which of the two roles [key] belongs to, spec section 5. "unknown" before
/// the create names who is who, or for a key that matches neither.
///
/// One shared place for this lookup, so the dashboard banner and the
/// transactions list cannot drift into naming roles differently.
String partnerRole(String key, Parties? parties) {
  if (parties != null && key == parties.investor) return 'investor';
  if (parties != null && key == parties.manager) return 'manager';
  return 'unknown';
}

/// [RecordStatus] as text for the transactions list and detail screen
/// (spec 6.1, 6.3, 6.4, 6.7). Purely cosmetic: the status itself is decided
/// by `recordStatuses` in qirad_core, never re-derived here.
String statusLabel(RecordStatus status) {
  switch (status) {
    case RecordStatus.effective:
      return 'Effective';
    case RecordStatus.pendingApproval:
      return 'Pending approval';
    case RecordStatus.rejected:
      return 'Rejected';
    case RecordStatus.cancelledByReversal:
      return 'Cancelled by reversal';
    case RecordStatus.overBudget:
      return 'Over budget';
    case RecordStatus.invalidResponse:
      return 'Invalid response (evidence)';
    case RecordStatus.ignoredResponse:
      return 'Ignored (later response)';
    case RecordStatus.chainInvalid:
      return 'Chain-invalid';
    case RecordStatus.equivocating:
      return 'Equivocating';
    case RecordStatus.notCounted:
      return 'Not counted';
  }
}
