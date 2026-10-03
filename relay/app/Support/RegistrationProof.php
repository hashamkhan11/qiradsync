<?php

namespace App\Support;

use Throwable;

/**
 * Checks that a phone holds the private key for a public key, by its signature
 * over a registration nonce (spec section 7.2).
 *
 * The signed bytes start with a fixed prefix. The prefix means a registration
 * signature can never be mistaken for a record signature (spec 4.2), even if
 * the same key signs both kinds of message.
 */
final class RegistrationProof
{
    public const PREFIX = 'qiradsync-register-v1:';

    public static function verify(string $publicKey, string $nonce, string $signature): bool
    {
        try {
            return sodium_crypto_sign_verify_detached(
                sodium_base642bin($signature, SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING),
                self::PREFIX.$nonce,
                sodium_base642bin($publicKey, SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING),
            );
        } catch (Throwable) {
            return false;
        }
    }
}
