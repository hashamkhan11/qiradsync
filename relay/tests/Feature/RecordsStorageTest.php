<?php

namespace Tests\Feature;

use Illuminate\Database\QueryException;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Tests\Support\TestIds;
use Tests\TestCase;

class RecordsStorageTest extends TestCase
{
    use RefreshDatabase;

    /** The shared vector, signed in Dart (packages/qirad_core). */
    private function vector(): array
    {
        return json_decode(
            file_get_contents(base_path('tests/Fixtures/record_vector.json')),
            true,
            512,
            JSON_THROW_ON_ERROR,
        );
    }

    /** @return array<string, mixed> */
    private function row(array $overrides = []): array
    {
        $v = $this->vector();

        return array_merge([
            'record_id' => $v['id'],
            'partnership' => $v['partnership'],
            'author' => $v['author'],
            'seq' => $v['seq'],
            'hash' => $v['hash'],
            'canonical' => $v['canonical'],
        ], $overrides);
    }

    public function test_a_urdu_record_is_stored_byte_for_byte(): void
    {
        $v = $this->vector();
        DB::table('records')->insert($this->row());

        $stored = DB::table('records')->where('record_id', $v['id'])->value('canonical');

        // Byte-for-byte: the same bytes that Dart signed and hashed.
        $this->assertSame($v['canonical'], $stored);
        // The string must really contain Urdu (non-ASCII), or the test proves little.
        $this->assertMatchesRegularExpression('/\p{Arabic}/u', $stored);
    }

    public function test_sha256_of_the_stored_string_matches_the_dart_hash(): void
    {
        $v = $this->vector();
        DB::table('records')->insert($this->row());

        $stored = DB::table('records')->where('record_id', $v['id'])->value('canonical');

        // The relay computes the hash from the exact stored bytes (spec 4.3).
        $this->assertSame($v['hash'], hash('sha256', $stored));
    }

    public function test_two_different_records_at_the_same_position_are_refused(): void
    {
        DB::table('records')->insert($this->row());

        $this->expectException(QueryException::class);
        DB::table('records')->insert($this->row(['record_id' => TestIds::of('another-id')]));
    }

    public function test_the_same_record_id_twice_is_refused(): void
    {
        DB::table('records')->insert($this->row());

        $this->expectException(QueryException::class);
        DB::table('records')->insert($this->row([
            'seq' => 2,
            'hash' => str_repeat('a', 64),
        ]));
    }

    public function test_an_update_is_refused_by_the_trigger(): void
    {
        DB::table('records')->insert($this->row());

        $this->expectException(QueryException::class);
        $this->expectExceptionMessage('records are append-only');
        DB::table('records')->update(['canonical' => '{}']);
    }

    public function test_a_delete_is_refused_by_the_trigger(): void
    {
        DB::table('records')->insert($this->row());

        $this->expectException(QueryException::class);
        $this->expectExceptionMessage('records are append-only');
        DB::table('records')->delete();
    }

    public function test_a_device_key_can_only_register_once(): void
    {
        DB::table('devices')->insert([
            'public_key' => $this->vector()['publicKey'],
            'created_at' => now(),
            'updated_at' => now(),
        ]);

        $this->expectException(QueryException::class);
        DB::table('devices')->insert([
            'public_key' => $this->vector()['publicKey'],
            'created_at' => now(),
            'updated_at' => now(),
        ]);
    }
}
