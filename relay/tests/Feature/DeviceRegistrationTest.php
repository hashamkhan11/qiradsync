<?php

namespace Tests\Feature;

use App\Models\Device;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Testing\TestResponse;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\TestCase;

class DeviceRegistrationTest extends TestCase
{
    use RefreshDatabase;

    /** A new Ed25519 key pair, as [publicKey, secretKey] in the wire format. */
    private function newDevice(): array
    {
        $pair = sodium_crypto_sign_keypair();

        return [
            sodium_bin2base64(sodium_crypto_sign_publickey($pair), SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING),
            sodium_crypto_sign_secretkey($pair),
        ];
    }

    private function sign(string $secretKey, string $message): string
    {
        return sodium_bin2base64(
            sodium_crypto_sign_detached($message, $secretKey),
            SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING,
        );
    }

    /** Ask the relay for a nonce for this key. */
    private function challengeFor(string $publicKey): string
    {
        return $this->postJson('/api/v1/devices/challenge', ['publicKey' => $publicKey])
            ->assertCreated()
            ->json('nonce');
    }

    private function registerWith(string $publicKey, string $nonce, string $signature): TestResponse
    {
        return $this->postJson('/api/v1/devices', [
            'publicKey' => $publicKey,
            'nonce' => $nonce,
            'signature' => $signature,
        ]);
    }

    /** A full, correct registration. Returns the token. */
    private function registerProperly(string $publicKey, string $secretKey): string
    {
        $nonce = $this->challengeFor($publicKey);
        $signature = $this->sign($secretKey, 'qiradsync-register-v1:'.$nonce);

        return $this->registerWith($publicKey, $nonce, $signature)
            ->assertCreated()
            ->json('token');
    }

    public function test_a_challenge_is_issued_and_stored_for_the_key(): void
    {
        [$publicKey] = $this->newDevice();

        $response = $this->postJson('/api/v1/devices/challenge', ['publicKey' => $publicKey])
            ->assertCreated()
            ->assertJsonStructure(['nonce', 'expiresAt']);

        $this->assertSame(43, strlen($response->json('nonce')));
        $this->assertDatabaseHas('device_challenges', [
            'public_key' => $publicKey,
            'nonce' => $response->json('nonce'),
        ]);
    }

    public function test_a_valid_proof_registers_the_key_and_gets_a_token(): void
    {
        [$publicKey, $secretKey] = $this->newDevice();

        $token = $this->registerProperly($publicKey, $secretKey);

        $this->assertNotEmpty($token);
        $this->assertDatabaseCount('devices', 1);
        $this->assertDatabaseHas('devices', ['public_key' => $publicKey]);
    }

    public function test_the_same_key_twice_reuses_one_device_but_issues_a_new_token(): void
    {
        [$publicKey, $secretKey] = $this->newDevice();

        $first = $this->registerProperly($publicKey, $secretKey);
        $second = $this->registerProperly($publicKey, $secretKey);

        $this->assertDatabaseCount('devices', 1);
        $this->assertNotSame($first, $second);
        $this->assertDatabaseCount('personal_access_tokens', 2);
    }

    public function test_the_token_belongs_to_the_device(): void
    {
        [$publicKey, $secretKey] = $this->newDevice();
        $this->registerProperly($publicKey, $secretKey);

        $device = Device::firstOrFail();
        $this->assertDatabaseHas('personal_access_tokens', [
            'tokenable_type' => Device::class,
            'tokenable_id' => $device->id,
        ]);
    }

    public function test_the_issued_token_authenticates(): void
    {
        [$publicKey, $secretKey] = $this->newDevice();
        $token = $this->registerProperly($publicKey, $secretKey);

        $this->withToken($token)
            ->getJson('/api/user')
            ->assertOk()
            ->assertJsonPath('public_key', $publicKey);
    }

    public function test_a_signature_from_a_different_key_is_refused(): void
    {
        [$publicKey] = $this->newDevice();
        [, $otherSecret] = $this->newDevice();
        $nonce = $this->challengeFor($publicKey);
        $wrongSignature = $this->sign($otherSecret, 'qiradsync-register-v1:'.$nonce);

        $this->registerWith($publicKey, $nonce, $wrongSignature)->assertUnprocessable();

        $this->assertDatabaseCount('devices', 0);
    }

    public function test_a_nonce_issued_for_another_key_is_refused(): void
    {
        [$publicKey, $secretKey] = $this->newDevice();
        [$otherKey] = $this->newDevice();
        $nonce = $this->challengeFor($publicKey);
        $signature = $this->sign($secretKey, 'qiradsync-register-v1:'.$nonce);

        $this->registerWith($otherKey, $nonce, $signature)->assertUnprocessable();

        $this->assertDatabaseCount('devices', 0);
    }

    public function test_an_expired_nonce_is_refused(): void
    {
        [$publicKey, $secretKey] = $this->newDevice();
        $nonce = $this->challengeFor($publicKey);
        $signature = $this->sign($secretKey, 'qiradsync-register-v1:'.$nonce);

        $this->travel(6)->minutes();
        $this->registerWith($publicKey, $nonce, $signature)->assertUnprocessable();
        $this->travelBack();

        $this->assertDatabaseCount('devices', 0);
    }

    public function test_a_reused_nonce_is_refused_as_a_replay(): void
    {
        [$publicKey, $secretKey] = $this->newDevice();
        $nonce = $this->challengeFor($publicKey);
        $signature = $this->sign($secretKey, 'qiradsync-register-v1:'.$nonce);

        $this->registerWith($publicKey, $nonce, $signature)->assertCreated();
        $this->registerWith($publicKey, $nonce, $signature)->assertUnprocessable();

        $this->assertDatabaseCount('devices', 1);
        $this->assertDatabaseCount('personal_access_tokens', 1);
    }

    public function test_a_failed_attempt_still_uses_up_the_nonce(): void
    {
        [$publicKey, $secretKey] = $this->newDevice();
        $nonce = $this->challengeFor($publicKey);
        $wrongSignature = $this->sign($secretKey, 'not the prefixed nonce');
        $rightSignature = $this->sign($secretKey, 'qiradsync-register-v1:'.$nonce);

        $this->registerWith($publicKey, $nonce, $wrongSignature)->assertUnprocessable();
        // The correct signature fails too: the first attempt already spent the nonce.
        $this->registerWith($publicKey, $nonce, $rightSignature)->assertUnprocessable();

        $this->assertDatabaseCount('devices', 0);
        $this->assertDatabaseMissing('device_challenges', ['nonce' => $nonce]);
    }

    public function test_a_signature_over_the_bare_nonce_is_refused(): void
    {
        [$publicKey, $secretKey] = $this->newDevice();
        $nonce = $this->challengeFor($publicKey);
        // Without the prefix this is a different message, so it must not register.
        $bareSignature = $this->sign($secretKey, $nonce);

        $this->registerWith($publicKey, $nonce, $bareSignature)->assertUnprocessable();

        $this->assertDatabaseCount('devices', 0);
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
    public function test_a_bad_key_gets_no_challenge(mixed $key): void
    {
        $this->postJson('/api/v1/devices/challenge', ['publicKey' => $key])
            ->assertUnprocessable()
            ->assertJsonValidationErrors(['publicKey']);

        $this->assertDatabaseCount('device_challenges', 0);
    }

    public function test_a_missing_key_is_refused(): void
    {
        $this->postJson('/api/v1/devices/challenge', [])
            ->assertUnprocessable()
            ->assertJsonValidationErrors(['publicKey']);

        $this->postJson('/api/v1/devices', [])
            ->assertUnprocessable()
            ->assertJsonValidationErrors(['publicKey', 'nonce', 'signature']);
    }
}
