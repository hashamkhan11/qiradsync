<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

class SyncRecordsRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    /**
     * `present` rather than `required`: an empty vector or an empty batch is a
     * normal request (a phone with nothing new to send), and `required` refuses
     * empty arrays. Each record is checked for real by the sync service.
     *
     * @return array<string, array<int, string>>
     */
    public function rules(): array
    {
        return [
            'vector' => ['present', 'array', 'max:10'],
            'vector.*' => ['integer', 'min:0'],
            'records' => ['present', 'array', 'max:500'],
            'records.*' => ['required', 'string', 'max:65536'],
        ];
    }
}
