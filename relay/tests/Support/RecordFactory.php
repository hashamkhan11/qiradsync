<?php

namespace Tests\Support;

use App\Support\CanonicalJson;

/**
 * Builds signed records in PHP, the way a phone does (spec 4.2).
 *
 * The keys made here come from fixed labels, so they are the same on every run.
 * They are TEST KEYS ONLY: they guard nothing, and they exist so that fixtures
 * in testdata/ can be regenerated and compared byte for byte.
 */
final class RecordFactory
{
    /** A key pair from a label, as [publicKey, secretKey] in the wire format. */
    public static function key(string $label): array
    {
        $seed = hash('sha256', 'qiradsync test key: '.$label, true);
        $pair = sodium_crypto_sign_seed_keypair($seed);

        return [
            sodium_bin2base64(sodium_crypto_sign_publickey($pair), SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING),
            sodium_crypto_sign_secretkey($pair),
        ];
    }

    /**
     * Sign the canonical form without `sig`, then add `sig` and encode again.
     * Defaults are overridden by whatever $fields sets. Returns the canonical text.
     */
    public static function signed(array $key, array $fields): string
    {
        $record = (object) ($fields + [
            'v' => 1,
            'author' => $key[0],
            'prevHash' => str_repeat('0', 64),
            'refersTo' => null,
            'time' => '2026-10-03T10:00:00Z',
        ]);

        $unsigned = CanonicalJson::encode($record);
        $record->sig = sodium_bin2base64(
            sodium_crypto_sign_detached($unsigned, $key[1]),
            SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
        );

        return CanonicalJson::encode($record);
    }
}
