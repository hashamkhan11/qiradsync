<?php

namespace Tests\Feature;

use App\Models\Device;
use App\Models\Partnership;
use App\Support\CanonicalJson;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Testing\TestResponse;
use Laravel\Sanctum\Sanctum;
use PHPUnit\Framework\Attributes\Test;
use Tests\TestCase;

class SyncRecordsTest extends TestCase
{
    use RefreshDatabase;

    private const PARTNERSHIP = 'partnership-1';

    private array $investor;

    private array $manager;

    private array $stranger;

    protected function setUp(): void
    {
        parent::setUp();

        $this->investor = $this->newKey();
        $this->manager = $this->newKey();
        $this->stranger = $this->newKey();
    }

    /** A new Ed25519 key pair, as [publicKey, secretKey] in the wire format. */
    private function newKey(): array
    {
        $pair = sodium_crypto_sign_keypair();

        return [
            sodium_bin2base64(sodium_crypto_sign_publickey($pair), SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING),
            sodium_crypto_sign_secretkey($pair),
        ];
    }

    /**
     * Build a record the way a phone does and sign it (spec 4.2): sign the
     * canonical form without `sig`, then add `sig` and encode again.
     * The defaults are overridden by whatever $fields sets.
     */
    private function signed(array $key, array $fields): string
    {
        $record = (object) ($fields + [
            'v' => 1,
            'author' => $key[0],
            'prevHash' => str_repeat('0', 64),
            'refersTo' => null,
            'time' => '2026-10-03T10:00:00Z',
        ]);

        $unsigned = CanonicalJson::encode($record);
        $record->sig = sodium_bin2base64(
            sodium_crypto_sign_detached($unsigned, $key[1]),
            SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
        );

        return CanonicalJson::encode($record);
    }

    /** The investor's partnership_create, which starts the partnership. */
    private function createText(): string
    {
        return $this->signed($this->investor, [
            'id' => self::PARTNERSHIP,
            'partnership' => self::PARTNERSHIP,
            'seq' => 1,
            'type' => 'partnership_create',
            'body' => (object) [
                'investor' => $this->investor[0],
                'manager' => $this->manager[0],
                'ratio' => (object) ['investor' => 60, 'manager' => 40],
                'currency' => 'PKR',
            ],
        ]);
    }

    private function investText(int $seq, string $id, int $amount = 150000): string
    {
        return $this->signed($this->investor, [
            'id' => $id,
            'partnership' => self::PARTNERSHIP,
            'seq' => $seq,
            'type' => 'invest',
            'body' => (object) ['amount' => $amount],
        ]);
    }

    /** Send a sync request as the given key's device. */
    private function syncAs(array $key, array $records, array $vector = []): TestResponse
    {
        Sanctum::actingAs(Device::firstOrCreate(['public_key' => $key[0]]));

        return $this->postJson('/api/v1/partnerships/'.self::PARTNERSHIP.'/sync', [
            'vector' => $vector,
            'records' => $records,
        ]);
    }

    private function startPartnership(): void
    {
        $this->syncAs($this->investor, [$this->createText()])->assertOk();
    }

    #[Test]
    public function the_investor_starts_the_partnership_and_the_record_is_stored(): void
    {
        $text = $this->createText();

        $this->syncAs($this->investor, [$text])
            ->assertOk()
            ->assertJsonPath('stored', [json_decode($text)->id])
            ->assertJsonPath('rejected', []);

        $this->assertSame(1, DB::table('records')->count());
        $this->assertSame(
            ['investor_key' => $this->investor[0], 'manager_key' => $this->manager[0]],
            Partnership::query()->first()->only(['investor_key', 'manager_key']),
        );
    }

    #[Test]
    public function records_are_stored_byte_for_byte_with_their_sha256_hash(): void
    {
        $text = $this->createText();

        $this->syncAs($this->investor, [$text])->assertOk();

        $row = DB::table('records')->first();
        $this->assertSame($text, $row->canonical);
        $this->assertSame(hash('sha256', $text), $row->hash);
    }

    #[Test]
    public function a_record_with_trailing_space_is_refused_not_trimmed(): void
    {
        // If Laravel trimmed the space, this would be canonical and stored.
        $this->startPartnership();
        $text = $this->investText(2, 'invest-2').' ';

        $this->syncAs($this->investor, [$text])
            ->assertOk()
            ->assertJsonPath('rejected.0.reason', 'not in canonical form')
            ->assertJsonPath('stored', []);

        $this->assertFalse(DB::table('records')->where('record_id', 'invest-2')->exists());
    }

    #[Test]
    public function a_record_with_a_bad_signature_is_refused(): void
    {
        $tampered = str_replace('"currency":"PKR"', '"currency":"USD"', $this->createText());

        $this->syncAs($this->investor, [$tampered])
            ->assertOk()
            ->assertJsonPath('rejected.0.reason', 'bad signature');

        $this->assertSame(0, DB::table('records')->count());
    }

    #[Test]
    public function the_manager_cannot_start_the_partnership(): void
    {
        $this->syncAs($this->manager, [$this->createText()])->assertForbidden();

        $this->assertSame(0, DB::table('records')->count());
    }

    #[Test]
    public function the_manager_can_sync_once_the_partnership_exists(): void
    {
        $this->startPartnership();

        $managerRecord = $this->signed($this->manager, [
            'id' => 'manager-rec-1',
            'partnership' => self::PARTNERSHIP,
            'seq' => 1,
            'type' => 'approve',
            'body' => new \stdClass,
        ]);

        $this->syncAs($this->manager, [$managerRecord])
            ->assertOk()
            ->assertJsonPath('stored', ['manager-rec-1']);
    }

    #[Test]
    public function a_stranger_device_is_refused_with_403(): void
    {
        $this->startPartnership();

        $this->syncAs($this->stranger, [])->assertForbidden();
    }

    #[Test]
    public function a_record_by_a_non_party_author_is_rejected(): void
    {
        $this->startPartnership();

        // The investor's device is allowed to sync, but the record's author is not a party.
        $outsider = $this->signed($this->stranger, [
            'id' => 'outsider-1',
            'partnership' => self::PARTNERSHIP,
            'seq' => 1,
            'type' => 'invest',
            'body' => (object) ['amount' => 1],
        ]);

        $this->syncAs($this->investor, [$outsider])
            ->assertJsonPath('rejected.0.reason', 'author is not a party to this partnership');
    }

    #[Test]
    public function a_record_for_another_partnership_is_rejected(): void
    {
        $this->startPartnership();

        $other = $this->signed($this->investor, [
            'id' => 'other-1',
            'partnership' => 'some-other-partnership',
            'seq' => 2,
            'type' => 'invest',
            'body' => (object) ['amount' => 1],
        ]);

        $this->syncAs($this->investor, [$other])
            ->assertJsonPath('rejected.0.reason', 'belongs to another partnership');
    }

    #[Test]
    public function a_body_that_is_an_array_is_refused(): void
    {
        $this->startPartnership();

        // Canonical text with `"body":[]`: it is valid JSON, but a body must be an object.
        $text = $this->signed($this->investor, [
            'id' => 'bad-body',
            'partnership' => self::PARTNERSHIP,
            'seq' => 2,
            'type' => 'invest',
            'body' => [],
        ]);

        $this->syncAs($this->investor, [$text])
            ->assertJsonPath('rejected.0.reason', 'body must be an object');
    }

    #[Test]
    public function the_relay_returns_only_the_records_the_phone_is_missing(): void
    {
        $this->startPartnership();
        $invest = $this->investText(2, 'invest-2');
        $this->syncAs($this->investor, [$invest])->assertOk();

        $investorKey = $this->investor[0];

        // The manager already holds seq 1 from the investor, so only seq 2 is missing.
        $this->syncAs($this->manager, [], [$investorKey => 1])
            ->assertOk()
            ->assertJsonPath('records', [$invest]);

        // A phone with nothing gets everything, in seq order.
        $all = $this->syncAs($this->manager, [], [])->json('records');
        $this->assertCount(2, $all);
        $this->assertSame(json_decode($all[0])->seq, 1);
        $this->assertSame(json_decode($all[1])->seq, 2);
    }

    #[Test]
    public function a_resent_identical_record_is_reported_as_already_stored(): void
    {
        $this->startPartnership();
        $invest = $this->investText(2, 'invest-2');
        $this->syncAs($this->investor, [$invest])->assertOk();

        $this->syncAs($this->investor, [$invest])
            ->assertJsonPath('already', ['invest-2'])
            ->assertJsonPath('stored', []);

        $this->assertSame(2, DB::table('records')->count());
    }

    #[Test]
    public function two_different_records_at_one_position_are_reported_as_a_conflict(): void
    {
        $this->startPartnership();
        $first = $this->investText(2, 'invest-2a', 100);
        $second = $this->investText(2, 'invest-2b', 200);

        $this->syncAs($this->investor, [$first])->assertOk();

        $response = $this->syncAs($this->investor, [$second])
            ->assertOk()
            ->assertJsonPath('stored', []);

        $conflict = $response->json('conflicts.0');
        $this->assertSame($this->investor[0], $conflict['author']);
        $this->assertSame(2, $conflict['seq']);
        $this->assertSame($first, $conflict['stored']);
        $this->assertSame($second, $conflict['received']);

        // The relay keeps the first record and never overwrites it.
        $this->assertSame($first, DB::table('records')->where('seq', 2)->value('canonical'));
    }

    #[Test]
    public function the_vector_is_the_highest_seq_stored_per_author(): void
    {
        $this->startPartnership();
        $this->syncAs($this->investor, [$this->investText(2, 'invest-2'), $this->investText(3, 'invest-3')])
            ->assertOk();

        $this->syncAs($this->investor, [])
            ->assertJsonPath('vector', [$this->investor[0] => 3]);
    }

    #[Test]
    public function requests_without_a_token_are_refused(): void
    {
        $this->postJson('/api/v1/partnerships/'.self::PARTNERSHIP.'/sync', [
            'vector' => [],
            'records' => [],
        ])->assertUnauthorized();
    }
}
