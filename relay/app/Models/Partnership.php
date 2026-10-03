<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Attributes\Fillable;
use Illuminate\Database\Eloquent\Model;

/**
 * The parties of one partnership, learned from its accepted partnership_create
 * (spec section 7.2, point 2). The id is the create's own id (spec section 3).
 * The relay keeps only these two keys. Everything else stays in the records.
 */
#[Fillable(['id', 'investor_key', 'manager_key'])]
class Partnership extends Model
{
    public $incrementing = false;

    protected $keyType = 'string';

    public $timestamps = false;
}
