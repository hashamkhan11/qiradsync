<?php

namespace Tests\Support;

/**
 * Turns a readable name into a fixed UUID v4 for tests (spec section 3).
 *
 * This is the same rule as testId() in packages/qirad_core/test/support, so a
 * name gives the same id in Dart and PHP. The input text is
 * '{"testId":"<name>"}', which is the canonical JSON the Dart side hashes.
 */
final class TestIds
{
    public static function of(string $name): string
    {
        $hex = substr(hash('sha256', '{"testId":"'.$name.'"}'), 0, 32);
        $hex[12] = '4';
        $hex[16] = '89ab'[hexdec($hex[16]) % 4];

        return substr($hex, 0, 8).'-'.substr($hex, 8, 4).'-'.substr($hex, 12, 4)
            .'-'.substr($hex, 16, 4).'-'.substr($hex, 20, 12);
    }
}
