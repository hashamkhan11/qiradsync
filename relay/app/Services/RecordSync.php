<?php

namespace App\Services;

use App\Models\Device;
use App\Models\Partnership;
use App\Support\ReceivedRecord;
use App\Support\RecordSignature;
use Illuminate\Support\Facades\DB;

/**
 * The sync step of spec section 7.2: store what the phone sends, report what
 * the phone is missing. The relay decides nothing about the ledger.
 */
final class RecordSync
{
    /**
     * @param  array<string, int>  $clientVector  highest seq the phone holds per author
     * @param  list<string>  $texts  records, each as the exact canonical text the phone sent
     * @return array<string, mixed>|null null when this device may not sync this partnership
     */
    public function sync(Device $device, string $partnershipId, array $clientVector, array $texts): ?array
    {
        $parsed = [];
        $rejected = [];
        foreach ($texts as $index => $text) {
            $record = ReceivedRecord::parse($text);
            if (is_string($record)) {
                $rejected[] = ['index' => $index, 'reason' => $record];

                continue;
            }
            $parsed[$index] = $record;
        }

        if (! $this->maySync($device, $partnershipId, $parsed)) {
            return null;
        }

        // The partnership_create goes first, so the parties are known before
        // the other records are checked. uasort keeps the original indexes and
        // is stable, so the rest keep the order the phone sent them in.
        uasort($parsed, fn (ReceivedRecord $a, ReceivedRecord $b) => ($b->type === 'partnership_create') <=> ($a->type === 'partnership_create'));

        return DB::transaction(function () use ($device, $partnershipId, $clientVector, $parsed, $rejected) {
            $stored = [];
            $already = [];
            $conflicts = [];

            foreach ($parsed as $index => $record) {
                $reason = $this->refusalReason($device, $partnershipId, $record);
                if ($reason !== null) {
                    $rejected[] = ['index' => $index, 'reason' => $reason];

                    continue;
                }

                $existing = DB::table('records')
                    ->where('partnership', $partnershipId)
                    ->where('author', $record->author)
                    ->where('seq', $record->seq)
                    ->first();

                // Same position: either a harmless re-send, or two different
                // records for one seq (equivocation). Both are kept as evidence,
                // but the relay never overwrites the stored one.
                if ($existing !== null) {
                    if ($existing->canonical === $record->text) {
                        $already[] = $record->id;
                    } else {
                        $conflicts[] = [
                            'author' => $record->author,
                            'seq' => $record->seq,
                            'stored' => $existing->canonical,
                            'received' => $record->text,
                        ];
                    }

                    continue;
                }

                DB::table('records')->insert([
                    'record_id' => $record->id,
                    'partnership' => $partnershipId,
                    'author' => $record->author,
                    'seq' => $record->seq,
                    'hash' => hash('sha256', $record->text),
                    'canonical' => $record->text,
                ]);
                $stored[] = $record->id;
            }

            usort($rejected, fn (array $a, array $b) => $a['index'] <=> $b['index']);

            return [
                'stored' => $stored,
                'already' => $already,
                'rejected' => $rejected,
                'conflicts' => $conflicts,
                'records' => $this->recordsMissingFrom($partnershipId, $clientVector),
                'vector' => (object) $this->vectorOf($partnershipId),
            ];
        });
    }

    /**
     * Spec 7.2, point 2. Once a partnership exists, only its two keys may sync.
     * Before that, the only device that may sync is the investor, and only to
     * send the partnership_create that starts the partnership.
     *
     * @param  array<int, ReceivedRecord>  $parsed
     */
    private function maySync(Device $device, string $partnershipId, array $parsed): bool
    {
        $partnership = Partnership::find($partnershipId);
        if ($partnership !== null) {
            return in_array($device->public_key, [$partnership->investor_key, $partnership->manager_key], true);
        }

        foreach ($parsed as $record) {
            if ($record->type === 'partnership_create'
                && $record->partnership === $partnershipId
                && $record->author === $device->public_key) {
                return true;
            }
        }

        return false;
    }

    /**
     * Why a parsed record must not be stored, or null if it may be. Each check
     * is one of spec 6.1's steps that the relay can make without the ledger.
     */
    private function refusalReason(Device $device, string $partnershipId, ReceivedRecord $record): ?string
    {
        if ($record->partnership !== $partnershipId) {
            return 'belongs to another partnership';
        }
        if (! RecordSignature::verify($record->text)) {
            return 'bad signature';
        }

        $partnership = Partnership::find($partnershipId);
        if ($partnership === null) {
            if ($record->type !== 'partnership_create' || $record->author !== $device->public_key) {
                return 'partnership has not been created yet';
            }

            $reason = $this->partnershipCreateRefusal($record);
            if ($reason !== null) {
                return $reason;
            }

            Partnership::create([
                'id' => $partnershipId,
                'investor_key' => $record->author,
                'manager_key' => $record->body->manager,
            ]);

            return null;
        }

        if (! in_array($record->author, [$partnership->investor_key, $partnership->manager_key], true)) {
            return 'author is not a party to this partnership';
        }

        return null;
    }

    /** The checks a partnership_create must pass before it starts a partnership. */
    private function partnershipCreateRefusal(ReceivedRecord $record): ?string
    {
        if ($record->id !== $record->partnership) {
            return 'partnership_create id must equal its partnership';
        }

        $manager = $record->body->manager ?? null;
        if (($record->body->investor ?? null) !== $record->author) {
            return 'investor must be the author of the partnership_create';
        }
        if (! is_string($manager) || ! preg_match('/^[A-Za-z0-9_-]{43}$/', $manager) || $manager === $record->author) {
            return 'manager key is not valid';
        }

        return null;
    }

    /**
     * Every stored record of the partnership that the phone does not have yet,
     * ordered by (author, seq). The phone's vector says which seq it holds.
     *
     * @param  array<string, int>  $clientVector
     * @return list<string>
     */
    private function recordsMissingFrom(string $partnershipId, array $clientVector): array
    {
        $partnership = Partnership::find($partnershipId);
        if ($partnership === null) {
            // Nothing was accepted, so there is nothing to send back.
            return [];
        }

        $parties = [$partnership->investor_key, $partnership->manager_key];
        sort($parties, SORT_STRING);

        $missing = [];
        foreach ($parties as $author) {
            $since = (int) ($clientVector[$author] ?? 0);

            $texts = DB::table('records')
                ->where('partnership', $partnershipId)
                ->where('author', $author)
                ->where('seq', '>', $since)
                ->orderBy('seq')
                ->pluck('canonical');

            array_push($missing, ...$texts->all());
        }

        return $missing;
    }

    /**
     * The relay's own vector, computed live from what it holds right now:
     * the highest seq it has per author.
     *
     * @return array<string, int>
     */
    private function vectorOf(string $partnershipId): array
    {
        return DB::table('records')
            ->where('partnership', $partnershipId)
            ->groupBy('author')
            ->selectRaw('author, max(seq) as top')
            ->pluck('top', 'author')
            ->map(fn ($top) => (int) $top)
            ->all();
    }
}
