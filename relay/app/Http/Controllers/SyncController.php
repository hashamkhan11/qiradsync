<?php

namespace App\Http\Controllers;

use App\Http\Requests\SyncRecordsRequest;
use App\Services\RecordSync;
use Illuminate\Http\JsonResponse;

class SyncController extends Controller
{
    /**
     * Exchange records for one partnership (spec section 7.2).
     * The service does the work. Here we only map its answer to HTTP.
     */
    public function store(SyncRecordsRequest $request, string $partnershipId, RecordSync $sync): JsonResponse
    {
        $result = $sync->sync(
            $request->user(),
            $partnershipId,
            $request->validated('vector'),
            $request->validated('records'),
        );

        if ($result === null) {
            return response()->json([
                'message' => 'This device is not allowed to sync this partnership. If you are creating it, upload a valid partnership_create signed by the investor.',
            ], 403);
        }

        return response()->json($result);
    }
}
