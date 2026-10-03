<?php

namespace App\Http\Controllers;

use App\Http\Requests\StoreDeviceRequest;
use App\Models\Device;
use Illuminate\Http\JsonResponse;

class DeviceController extends Controller
{
    /**
     * Register a device key and return a token for it (spec section 7.2).
     *
     * Registering the same key again is harmless: it reuses the one device row
     * and issues a fresh token. The relay trusts a key only as an identity; a
     * device can never write a record it did not sign (checked at sync time).
     */
    public function store(StoreDeviceRequest $request): JsonResponse
    {
        $device = Device::firstOrCreate([
            'public_key' => $request->validated('publicKey'),
        ]);

        $token = $device->createToken('device')->plainTextToken;

        return response()->json(['token' => $token], 201);
    }
}
