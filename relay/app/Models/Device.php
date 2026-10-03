<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Model;
use Laravel\Sanctum\HasApiTokens;

/**
 * A phone, identified only by its Ed25519 public key (spec section 2).
 * Tokens are Sanctum tokens: they let a device call the sync endpoint.
 */
#[Fillable(['public_key'])]
class Device extends Model
{
    use HasApiTokens;
}
