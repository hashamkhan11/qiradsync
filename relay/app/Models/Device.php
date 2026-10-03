<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Foundation\Auth\User as Authenticatable;
use Laravel\Sanctum\HasApiTokens;

/**
 * A phone, identified only by its Ed25519 public key (spec section 2).
 * Tokens are Sanctum tokens: they let a device call the sync endpoint.
 * Sanctum needs the token owner to be an Authenticatable, like Laravel's User.
 */
#[Fillable(['public_key'])]
class Device extends Authenticatable
{
    use HasApiTokens;
}
