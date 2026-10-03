<?php

namespace App\Support;

use InvalidArgumentException;
use stdClass;

/**
 * Canonical JSON, exactly as spec section 4.1 and packages/qirad_core's
 * canonicalJson. The relay needs it to rebuild the bytes a phone signed.
 *
 * The rules must match Dart byte for byte, or every signature check fails:
 * - object keys sorted by Unicode code point (strcmp on UTF-8 bytes gives that order)
 * - no whitespace
 * - strings are UTF-8, escaped as JSON, but non-ASCII is written as-is
 * - integers only; any float is refused
 */
final class CanonicalJson
{
    /**
     * Parse a JSON string and write it back in canonical form.
     *
     * Objects are decoded as stdClass so an empty `{}` stays `{}` and is not
     * turned into `[]`, which would change the bytes.
     */
    public static function fromJsonString(string $json): string
    {
        return self::encode(json_decode($json, false, 512, JSON_THROW_ON_ERROR));
    }

    /**
     * @throws InvalidArgumentException for floats or values JSON cannot hold
     */
    public static function encode(mixed $value): string
    {
        if ($value === null) {
            return 'null';
        }
        if (is_bool($value)) {
            return $value ? 'true' : 'false';
        }
        if (is_int($value)) {
            return (string) $value;
        }
        if (is_float($value)) {
            throw new InvalidArgumentException('canonical JSON does not allow floats');
        }
        if (is_string($value)) {
            return self::encodeString($value);
        }
        if ($value instanceof stdClass) {
            $fields = get_object_vars($value);
            ksort($fields, SORT_STRING);

            $parts = [];
            foreach ($fields as $key => $field) {
                $parts[] = self::encodeString((string) $key).':'.self::encode($field);
            }

            return '{'.implode(',', $parts).'}';
        }
        if (is_array($value)) {
            // A JSON array. Decoded arrays are always lists here, because objects
            // were decoded as stdClass.
            return '['.implode(',', array_map(self::encode(...), $value)).']';
        }

        throw new InvalidArgumentException('canonical JSON cannot encode this value');
    }

    private static function encodeString(string $value): string
    {
        // U+2028 and U+2029 must stay raw: Dart's jsonEncode does not escape them,
        // and PHP would, which would change the bytes.
        $encoded = json_encode(
            $value,
            JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_LINE_TERMINATORS,
        );
        if ($encoded === false) {
            throw new InvalidArgumentException('string is not valid UTF-8');
        }

        return $encoded;
    }
}
