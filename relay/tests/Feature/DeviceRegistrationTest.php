<?php

namespace Tests\Feature;

use App\Models\Device;
use Illuminate\Foundation\Testing\RefreshDatabase;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\TestCase;

class DeviceRegistrationTest extends TestCase
{
    use RefreshDatabase;

    private function publicKey(): string
    {
        return json_decode(
            file_get_contents(base_path('tests/Fixtures/record_vector.json')),
            true,
            512,
            JSON_THROW_ON_ERROR,
        )['publicKey'];
    }

    public function test_a_new_key_is_registered_and_gets_a_token(): void
    {
        $response = $this->postJson('/api/v1/devices', ['publicKey' => $this->publicKey()]);

        $response->assertCreated()->assertJsonStructure(['token']);
        $this->assertDatabaseCount('devices', 1);
        $this->assertDatabaseHas('devices', ['public_key' => $this->publicKey()]);
    }

    public function test_the_same_key_twice_reuses_one_device_but_issues_a_new_token(): void
    {
        $first = $this->postJson('/api/v1/devices', ['publicKey' => $this->publicKey()])
            ->assertCreated()->json('token');
        $second = $this->postJson('/api/v1/devices', ['publicKey' => $this->publicKey()])
            ->assertCreated()->json('token');

        $this->assertDatabaseCount('devices', 1);
        $this->assertNotSame($first, $second);
        $this->assertDatabaseCount('personal_access_tokens', 2);
    }

    public function test_the_token_belongs_to_the_device(): void
    {
        $this->postJson('/api/v1/devices', ['publicKey' => $this->publicKey()]);

        $device = Device::firstOrFail();
        $this->assertDatabaseHas('personal_access_tokens', [
            'tokenable_type' => Device::class,
            'tokenable_id' => $device->id,
        ]);
    }

    public function test_the_issued_token_authenticates(): void
    {
        $token = $this->postJson('/api/v1/devices', ['publicKey' => $this->publicKey()])
            ->json('token');

        $this->withToken($token)
            ->getJson('/api/user')
            ->assertOk()
            ->assertJsonPath('public_key', $this->publicKey());
    }

    /** @return array<string, array{0: mixed}> */
    public static function badKeys(): array
    {
        return [
            'too short' => ['abc'],
            'too long' => [str_repeat('A', 44)],
            'padded with =' => [str_repeat('A', 42).'='],
            'not base64url (+)' => [str_repeat('A', 42).'+'],
            'empty string' => [''],
            'not a string' => [12345],
        ];
    }

    #[DataProvider('badKeys')]
    public function test_a_bad_key_is_refused_and_nothing_is_stored($key): void
    {
        $this->postJson('/api/v1/devices', ['publicKey' => $key])
            ->assertUnprocessable()
            ->assertJsonValidationErrors(['publicKey']);

        $this->assertDatabaseCount('devices', 0);
    }

    public function test_a_missing_key_is_refused(): void
    {
        $this->postJson('/api/v1/devices', [])
            ->assertUnprocessable()
            ->assertJsonValidationErrors(['publicKey']);
    }
}
