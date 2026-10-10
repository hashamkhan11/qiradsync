/// Parses rupee text a person typed into whole paisa (hard rule 1: money is
/// always an integer, never a `double`). `null` means the text is not a
/// valid amount — digits, optional comma thousands separators, and at most
/// two decimal places. A negative sign, more than two decimal digits, or
/// anything else (letters, a bare "-", an empty field) are all rejected the
/// same way, rather than guessed at: a form shows "enter a valid amount"
/// and proposes nothing. Leading/trailing whitespace is trimmed first — a
/// stray space around what someone typed is not a reason to refuse it.
int? parseRupeesToPaisa(String typed) {
  final text = typed.trim().replaceAll(',', '');
  final match = RegExp(r'^(\d+)(?:\.(\d{1,2}))?$').firstMatch(text);
  if (match == null) return null;

  final rupees = int.parse(match.group(1)!);
  final paisaDigits = (match.group(2) ?? '').padRight(2, '0');
  return rupees * 100 + int.parse(paisaDigits);
}
