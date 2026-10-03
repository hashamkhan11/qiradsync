<?php

namespace App\Http\Controllers;

use App\Http\Requests\IssueDeviceChallengeRequest;
use App\Http\Requests\StoreDeviceRequest;
use App\Models\Device;
use App\Models\DeviceChallenge;
use App\Support\RegistrationProof;
use Illuminate\Http\JsonResponse;

class DeviceController extends Controller
{
    /** How long a registration nonce stays valid. */
    private const CHALLENGE_MINUTES = 5;

    /**
     * Issue a single-use nonce for a public key (spec section 7.2, step 1).
     * The phone must sign it to prove it holds the private key.
     */
    public function challenge(IssueDeviceChallengeRequest $request): JsonResponse
    {
        // Expired nonces are only ever refused, so drop them to keep the table small.
        DeviceChallenge::query()->where('expires_at', '<', now())->delete();

        $nonce = sodium_bin2base64(random_bytes(32), SODIUM_BASE64_VARIANT_URLSAFE_NO_PADDING);
        $challenge = DeviceChallenge::create([
            'public_key' => $request->validated('publicKey'),
            'nonce' => $nonce,
            'expires_at' => now()->addMinutes(self::CHALLENGE_MINUTES),
        ]);

        return response()->json([
            'nonce' => $nonce,
            'expiresAt' => $challenge->expires_at->toIso8601String(),
        ], 201);
    }

    /**
     * Register a device key and return a token for it (spec section 7.2, step 2).
     *
     * The nonce is spent before the signature is checked, so a nonce is used up
     * whether the attempt succeeds or fails. The refusal message is the same for
     * every failure, so a caller learns nothing about which check failed.
     *
     * Registering the same key again is harmless: it reuses the one device row
     * and issues a fresh token. A device can never write a record it did not
     * sign (checked at sync time).
     */
    public function store(StoreDeviceRequest $request): JsonResponse
    {
        $publicKey = $request->validated('publicKey');
        $nonce = $request->validated('nonce');
        $signature = $request->validated('signature');

        $nonceIsValid = DeviceChallenge::consume($publicKey, $nonce);
        if (! $nonceIsValid || ! RegistrationProof::verify($publicKey, $nonce, $signature)) {
            return response()->json(['message' => 'Registration refused.'], 422);
        }

        $device = Device::firstOrCreate(['public_key' => $publicKey]);
        $token = $device->createToken('device')->plainTextToken;

        return response()->json(['token' => $token], 201);
    }
}
