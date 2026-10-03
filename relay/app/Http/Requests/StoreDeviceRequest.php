<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

class StoreDeviceRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    /**
     * A public key is base64url without padding, always 43 characters
     * (spec section 2). A nonce has the same shape. An Ed25519 signature is
     * 64 bytes, which is 86 characters in base64url without padding.
     *
     * @return array<string, array<int, string>>
     */
    public function rules(): array
    {
        return [
            'publicKey' => ['required', 'string', 'regex:/^[A-Za-z0-9_-]{43}$/'],
            'nonce' => ['required', 'string', 'regex:/^[A-Za-z0-9_-]{43}$/'],
            'signature' => ['required', 'string', 'regex:/^[A-Za-z0-9_-]{86}$/'],
        ];
    }
}
