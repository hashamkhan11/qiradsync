<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * Versions that clash with a stored record: the same (author, seq) with a
     * different hash. This is equivocation evidence (spec 6.1 step 5).
     *
     * The original stays in `records`. A conflicting version goes here, so
     * every partner can receive both versions and run its own check.
     * Like `records`, rows are written once and never changed or removed.
     */
    public function up(): void
    {
        Schema::create('conflicts', function (Blueprint $table) {
            $table->id();
            $table->string('partnership');
            $table->string('author', 43);
            $table->unsignedBigInteger('seq');
            // Unique: the same conflicting text is stored once, however often it is re-sent.
            $table->char('hash', 64)->unique();
            $table->text('canonical');
            $table->index(['partnership', 'author', 'seq']);
        });

        if (DB::getDriverName() === 'sqlite') {
            DB::unprepared(<<<'SQL'
                CREATE TRIGGER conflicts_block_update BEFORE UPDATE ON conflicts
                BEGIN
                    SELECT RAISE(ABORT, 'conflicts are append-only');
                END;
            SQL);
            DB::unprepared(<<<'SQL'
                CREATE TRIGGER conflicts_block_delete BEFORE DELETE ON conflicts
                BEGIN
                    SELECT RAISE(ABORT, 'conflicts are append-only');
                END;
            SQL);
        }
    }

    public function down(): void
    {
        if (DB::getDriverName() === 'sqlite') {
            DB::unprepared('DROP TRIGGER IF EXISTS conflicts_block_update');
            DB::unprepared('DROP TRIGGER IF EXISTS conflicts_block_delete');
        }
        Schema::dropIfExists('conflicts');
    }
};
