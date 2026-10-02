/// Canonical JSON encoding, exactly as spec section 4.1.
///
/// Signatures and hashes only work if every device produces the exact same
/// bytes for the same record. `dart:convert`'s `jsonEncode` does not sort
/// map keys, so this walks the value by hand instead of trusting it to.
library;

import 'dart:convert';

/// Encodes [value] (a JSON-compatible `Map`, `List`, `String`, `int`,
/// `bool` or `null`) as canonical JSON: object keys sorted by Unicode code
/// point at every nesting level, no whitespace, no floats.
String canonicalJson(Object? value) {
  final buffer = StringBuffer();
  _writeCanonical(value, buffer);
  return buffer.toString();
}

void _writeCanonical(Object? value, StringBuffer buffer) {
  if (value == null) {
    buffer.write('null');
  } else if (value is String) {
    buffer.write(jsonEncode(value));
  } else if (value is bool) {
    buffer.write(value);
  } else if (value is int) {
    buffer.write(value);
  } else if (value is double) {
    throw ArgumentError(
      'canonicalJson does not allow floats: $value. Money and all other '
      'numbers must be integers.',
    );
  } else if (value is Map) {
    final keys = value.keys.map((k) => k as String).toList()..sort();
    buffer.write('{');
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) buffer.write(',');
      buffer.write(jsonEncode(keys[i]));
      buffer.write(':');
      _writeCanonical(value[keys[i]], buffer);
    }
    buffer.write('}');
  } else if (value is List) {
    buffer.write('[');
    for (var i = 0; i < value.length; i++) {
      if (i > 0) buffer.write(',');
      _writeCanonical(value[i], buffer);
    }
    buffer.write(']');
  } else {
    throw ArgumentError('canonicalJson cannot encode: $value');
  }
}
