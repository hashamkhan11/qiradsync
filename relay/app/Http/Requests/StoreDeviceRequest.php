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
     * (spec section 2). Anything else cannot be a real key, so it is refused.
     *
     * @return array<string, array<int, string>>
     */
    public function rules(): array
    {
        return [
            'publicKey' => ['required', 'string', 'regex:/^[A-Za-z0-9_-]{43}$/'],
        ];
    }
}
