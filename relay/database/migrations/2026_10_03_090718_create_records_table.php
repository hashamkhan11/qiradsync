<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * The relay's copy of every signed record (spec section 7.2).
     *
     * Records are append-only: a row is written once and never changed or
     * removed (hard rule 2 and 7). The `canonical` column keeps the exact string
     * the phone sent, so the signature and hash can always be checked again.
     */
    public function up(): void
    {
        Schema::create('records', function (Blueprint $table) {
            $table->id();
            // Named record_id, not id, so it is never confused with this row's key.
            $table->string('record_id')->unique();
            $table->string('partnership');
            $table->string('author', 43);
            $table->unsignedBigInteger('seq');
            $table->char('hash', 64);
            // The exact canonical JSON string. Never re-encoded (hard rule 7).
            $table->text('canonical');

            // The database refuses two different records at one position.
            // Conflicts are reported to the phone, never stored (spec 7.2).
            $table->unique(['partnership', 'author', 'seq']);
            // No timestamps: records never change, so there is no updated_at.
        });

        // SQLite has no way to revoke UPDATE or DELETE, so triggers block them.
        // This is a backstop: the application code also never runs them.
        if (DB::getDriverName() === 'sqlite') {
            DB::unprepared(<<<'SQL'
                CREATE TRIGGER records_block_update BEFORE UPDATE ON records
                BEGIN
                    SELECT RAISE(ABORT, 'records are append-only');
                END;
            SQL);
            DB::unprepared(<<<'SQL'
                CREATE TRIGGER records_block_delete BEFORE DELETE ON records
                BEGIN
                    SELECT RAISE(ABORT, 'records are append-only');
                END;
            SQL);
        }
    }

    public function down(): void
    {
        if (DB::getDriverName() === 'sqlite') {
            DB::unprepared('DROP TRIGGER IF EXISTS records_block_update');
            DB::unprepared('DROP TRIGGER IF EXISTS records_block_delete');
        }
        Schema::dropIfExists('records');
    }
};
