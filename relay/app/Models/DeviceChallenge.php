<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Support\Facades\DB;

/**
 * A registration challenge: a random nonce the phone must sign to prove it
 * holds the private key for a public key (spec section 7.2).
 */
#[Fillable(['public_key', 'nonce', 'expires_at'])]
class DeviceChallenge extends Model
{
    public $timestamps = false;

    protected function casts(): array
    {
        return ['expires_at' => 'datetime'];
    }

    /**
     * Spend a nonce. Returns true only if it was issued for this key and has not
     * expired. The row is deleted either way, so a nonce can never be tried twice.
     *
     * The delete count is checked, not assumed: if two requests race for the
     * same nonce, only the one that really deletes the row gets true.
     */
    public static function consume(string $publicKey, string $nonce): bool
    {
        return DB::transaction(function () use ($publicKey, $nonce) {
            $challenge = static::query()
                ->where('public_key', $publicKey)
                ->where('nonce', $nonce)
                ->first();

            if ($challenge === null) {
                return false;
            }

            $deleted = static::query()->whereKey($challenge->id)->delete();

            return $deleted === 1 && $challenge->expires_at->isFuture();
        });
    }
}
