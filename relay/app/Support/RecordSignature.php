<?php

namespace App\Support;

use Throwable;

/**
 * Checks a record's Ed25519 signature the way spec section 4.2 says:
 * the signed bytes are canonical(record without "sig"), and the public key is
 * the record's own `author`.
 *
 * Returns false for any malformed input. This is a trust boundary: the relay
 * must never crash or believe a record because its input was odd.
 */
final class RecordSignature
{
    public static function verify(string $canonicalRecord): bool
    {
        try {
            $record = json_decode($canonicalRecord, false, 512, JSON_THROW_ON_ERROR);
            if (! is_object($record)) {
                return false;
            }

            $author = $record->author ?? null;
            $sig = $record->sig ?? null;
            if (! is_string($author) || ! is_string($sig)) {
                return false;
            }

            unset($record->sig);
            $signed = CanonicalJson::encode($record);

            $publicKey = sodium_base642bin($author, SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING);
            $signature = sodium_base642bin($sig, SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING);

            return sodium_crypto_sign_verify_detached($signature, $signed, $publicKey);
        } catch (Throwable) {
            return false;
        }
    }
}
