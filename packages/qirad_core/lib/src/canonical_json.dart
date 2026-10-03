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

/// Compares two strings by Unicode code point, the order spec section 4.1 asks for.
///
/// `String.compareTo` compares UTF-16 code units, which is a different order
/// for characters above U+FFFF: an emoji (U+1F600) would sort before U+FF5E
/// even though its code point is larger. Every device and the relay must
/// agree on the order, so we compare code points directly.
int _compareCodePoints(String a, String b) {
  final first = a.runes.iterator;
  final second = b.runes.iterator;
  while (true) {
    final hasFirst = first.moveNext();
    final hasSecond = second.moveNext();
    if (!hasFirst || !hasSecond) {
      // The shorter string (one that ran out first) sorts before the longer one.
      return (hasFirst ? 1 : 0) - (hasSecond ? 1 : 0);
    }
    final order = first.current.compareTo(second.current);
    if (order != 0) return order;
  }
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
    final keys = value.keys.map((k) => k as String).toList()
      ..sort(_compareCodePoints);
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
