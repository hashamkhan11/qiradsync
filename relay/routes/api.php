<?php

use App\Http\Controllers\DeviceController;
use App\Http\Controllers\SyncController;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Route;

Route::prefix('v1')->group(function () {
    Route::post('/devices/challenge', [DeviceController::class, 'challenge']);
    Route::post('/devices', [DeviceController::class, 'store']);

    Route::post('/partnerships/{partnershipId}/sync', [SyncController::class, 'store'])
        ->where('partnershipId', '[A-Za-z0-9_-]{1,64}')
        ->middleware('auth:sanctum');
});

Route::get('/user', function (Request $request) {
    return $request->user();
})->middleware('auth:sanctum');
