<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * One row per issued registration challenge (spec section 7.2). A nonce is
     * single use and expires after 5 minutes. The row is deleted when the nonce
     * is used, whether the registration succeeds or fails.
     */
    public function up(): void
    {
        Schema::create('device_challenges', function (Blueprint $table) {
            $table->id();
            $table->string('public_key', 43)->index();
            // Random 32 bytes, base64url without padding: always 43 characters.
            $table->string('nonce', 43)->unique();
            $table->timestamp('expires_at')->index();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('device_challenges');
    }
};
