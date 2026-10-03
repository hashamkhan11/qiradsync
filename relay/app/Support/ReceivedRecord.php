<?php

namespace App\Support;

use InvalidArgumentException;
use JsonException;

/**
 * One record as the relay reads it: the exact text, plus the few fields the
 * relay needs to store it and to check who may send it.
 *
 * The relay never interprets the rest of the record (spec 7.2). It stores the
 * text it received, byte for byte, so the phones hash and verify the same bytes.
 */
final readonly class ReceivedRecord
{
    private function __construct(
        public string $text,
        public string $id,
        public string $partnership,
        public string $author,
        public int $seq,
        public string $type,
        public object $body,
    ) {}

    /**
     * Returns the record, or the reason it was refused.
     *
     * The canonical check comes first: a text that is not in canonical form
     * cannot be stored as it is, whatever else is wrong with it.
     */
    public static function parse(string $text): self|string
    {
        try {
            $decoded = json_decode($text, false, 512, JSON_THROW_ON_ERROR);
            $canonical = CanonicalJson::fromJsonString($text);
        } catch (JsonException|InvalidArgumentException) {
            return 'not valid canonical JSON';
        }

        if (! is_object($decoded)) {
            return 'not a JSON object';
        }
        if ($canonical !== $text) {
            return 'not in canonical form';
        }

        $id = $decoded->id ?? null;
        $partnership = $decoded->partnership ?? null;
        $author = $decoded->author ?? null;
        $seq = $decoded->seq ?? null;
        $type = $decoded->type ?? null;
        $body = $decoded->body ?? null;

        if (! is_string($id) || $id === '') {
            return 'missing id';
        }
        if (! is_string($partnership) || $partnership === '') {
            return 'missing partnership';
        }
        if (! is_string($author) || $author === '') {
            return 'missing author';
        }
        if (! is_int($seq) || $seq < 1) {
            return 'seq must be a positive integer';
        }
        if (! is_string($type) || $type === '') {
            return 'missing type';
        }
        // `body: []` is canonical text, but a body is always an object (spec 3).
        if (! is_object($body)) {
            return 'body must be an object';
        }

        return new self($text, $id, $partnership, $author, $seq, $type, $body);
    }
}
