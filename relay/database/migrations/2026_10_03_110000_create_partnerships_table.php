<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    /**
     * One row per partnership: its id and its two keys. A partnership starts
     * with its investor's accepted partnership_create (spec sections 3 and 7.2).
     */
    public function up(): void
    {
        Schema::create('partnerships', function (Blueprint $table) {
            $table->string('id', 64)->primary();
            $table->string('investor_key', 43);
            $table->string('manager_key', 43);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('partnerships');
    }
};
