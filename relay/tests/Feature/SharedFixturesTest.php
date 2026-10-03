<?php

namespace Tests\Feature;

use App\Models\Device;
use App\Support\CanonicalJson;
use App\Support\ReceivedRecord;
use App\Support\RecordSignature;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Laravel\Sanctum\Sanctum;
use PHPUnit\Framework\Attributes\Test;
use Tests\Support\RecordFactory;
use Tests\Support\TestIds;
use Tests\TestCase;

/**
 * Shared fixtures in testdata/, in both directions.
 *
 * Dart -> PHP: testdata/dart_signed_records.json is written by the Dart tool
 * (packages/qirad_core/tool/generate_fixtures.dart). The relay must verify it.
 *
 * PHP -> Dart: testdata/relay_equivocation_sync.json is a real sync response
 * from this relay. It is written by this test when QIRAD_WRITE_FIXTURES=1.
 * The Dart test reads it and must flag the manager for equivocation.
 *
 * Never edit the files in testdata/ by hand.
 */
class SharedFixturesTest extends TestCase
{
    use RefreshDatabase;

    private const DART_FIXTURE = '../testdata/dart_signed_records.json';

    private const RELAY_FIXTURE = '../testdata/relay_equivocation_sync.json';

    private const REGISTRATION_VECTOR = '../testdata/registration_vector.json';

    private const RELAY_PARTNERSHIP = 'cdbe037a-aa7f-4c99-b816-1840578fcc4c'; // TestIds::of('partnership-relay-fixture')

    #[Test]
    public function the_relay_verifies_and_stores_records_signed_in_dart(): void
    {
        $fixture = json_decode(file_get_contents(base_path(self::DART_FIXTURE)), true, 512, JSON_THROW_ON_ERROR);
        $records = $fixture['records'];
        $expected = $fixture['expected'];

        foreach ($records as $i => $text) {
            $this->assertTrue(RecordSignature::verify($text), "signature of record $i");
            $this->assertSame($text, CanonicalJson::fromJsonString($text), "canonical form of record $i");
            $this->assertInstanceOf(ReceivedRecord::class, ReceivedRecord::parse($text));
            $this->assertSame($expected[$i]['hash'], hash('sha256', $text), "hash of record $i");
            $this->assertSame($expected[$i]['id'], json_decode($text, true)['id']);
        }

        // The first record is the investor's partnership_create, so the device
        // that uploads the batch is the investor's device.
        $create = json_decode($records[0], true);
        $this->actAs($create['author']);

        $response = $this->postJson("/api/v1/partnerships/{$create['partnership']}/sync", [
            'vector' => [],
            'records' => $records,
        ]);

        $response->assertOk();
        $response->assertJson([
            'accepted' => array_column($expected, 'id'),
            'already' => [],
            'rejected' => [],
        ]);
    }

    #[Test]
    public function the_relay_accepts_a_registration_signed_in_dart(): void
    {
        $vector = json_decode(
            file_get_contents(base_path(self::REGISTRATION_VECTOR)),
            true,
            512,
            JSON_THROW_ON_ERROR,
        );

        // A real relay issues this nonce from /devices/challenge. The Dart
        // signature is over this fixed nonce, so the test stores it directly.
        DB::table('device_challenges')->insert([
            'public_key' => $vector['publicKey'],
            'nonce' => $vector['nonce'],
            'expires_at' => now()->addMinutes(5),
        ]);

        $this->postJson('/api/v1/devices', [
            'publicKey' => $vector['publicKey'],
            'nonce' => $vector['nonce'],
            'signature' => $vector['signature'],
        ])->assertCreated()->assertJsonStructure(['token']);
    }

    #[Test]
    public function the_relay_response_for_two_versions_of_seq_5_matches_the_fixture(): void
    {
        $investor = RecordFactory::key('investor');
        $manager = RecordFactory::key('manager');
        $partnership = self::RELAY_PARTNERSHIP;

        $create = RecordFactory::signed($investor, [
            'id' => $partnership,
            'partnership' => $partnership,
            'seq' => 1,
            'type' => 'partnership_create',
            'body' => (object) [
                'investor' => $investor[0],
                'manager' => $manager[0],
                'ratio' => (object) ['investor' => 60, 'manager' => 40],
                'currency' => 'PKR',
            ],
            'note' => '',
        ]);
        $invest = RecordFactory::signed($investor, [
            'id' => TestIds::of('invest-2'),
            'partnership' => $partnership,
            'seq' => 2,
            'type' => 'invest',
            'prevHash' => hash('sha256', $create),
            'body' => (object) ['amount' => 150000],
            'note' => '',
        ]);

        // The manager writes two different records at the same position (seq 5).
        $approveA = $this->approve($manager, $partnership, 5, TestIds::of('approve-5a'));
        $approveB = $this->approve($manager, $partnership, 5, TestIds::of('approve-5b'));

        $this->actAs($investor[0]);
        $this->syncRecords($partnership, [$create, $invest]);

        $this->actAs($manager[0]);
        $this->syncRecords($partnership, [$approveA]);
        $this->syncRecords($partnership, [$approveB]);

        // The investor syncs with an empty vector, so it gets everything it is missing.
        $this->actAs($investor[0]);
        $body = $this->syncRecords($partnership, [], []);

        $this->assertSame([$approveA, $approveB], $body['conflicts'], 'both versions of seq 5 are sent');

        $file = base_path(self::RELAY_FIXTURE);
        $bytes = json_encode(
            ['partnership' => $partnership, 'response' => $body],
            JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_LINE_TERMINATORS,
        )."\n";

        if (getenv('QIRAD_WRITE_FIXTURES') === '1') {
            file_put_contents($file, $bytes);
        }

        $this->assertFileExists($file, 'Run with QIRAD_WRITE_FIXTURES=1 to create it.');
        $this->assertSame(
            file_get_contents($file),
            $bytes,
            'The fixture is stale. Run: QIRAD_WRITE_FIXTURES=1 php artisan test --filter=SharedFixturesTest',
        );
    }

    /** A manager's approve record at a given seq. Body is empty (spec 5). */
    private function approve(array $manager, string $partnership, int $seq, string $id): string
    {
        return RecordFactory::signed($manager, [
            'id' => $id,
            'partnership' => $partnership,
            'seq' => $seq,
            'type' => 'approve',
            'refersTo' => TestIds::of('invest-2'),
            'body' => (object) [],
            'note' => '',
        ]);
    }

    /** Sign in as a device with this public key. */
    private function actAs(string $publicKey): void
    {
        Sanctum::actingAs(Device::firstOrCreate(['public_key' => $publicKey]));
    }

    /** POST records and return the decoded response body. */
    private function syncRecords(string $partnership, array $records, array $vector = []): array
    {
        $response = $this->postJson("/api/v1/partnerships/$partnership/sync", [
            'vector' => (object) $vector,
            'records' => $records,
        ]);

        $response->assertOk();

        return $response->json();
    }
}
