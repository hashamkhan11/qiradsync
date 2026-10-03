<?php

namespace Tests\Unit;

use App\Support\CanonicalJson;
use InvalidArgumentException;
use PHPUnit\Framework\Attributes\Test;
use PHPUnit\Framework\TestCase;

class CanonicalJsonTest extends TestCase
{
    #[Test]
    public function the_shared_vector_is_already_in_canonical_form(): void
    {
        // Re-encoding the Dart-made string must give the same bytes back. If this
        // fails, every signature check would fail too.
        $vector = json_decode(
            file_get_contents(__DIR__.'/../Fixtures/record_vector.json'),
            true,
            512,
            JSON_THROW_ON_ERROR,
        );

        $this->assertSame($vector['canonical'], CanonicalJson::fromJsonString($vector['canonical']));
    }

    #[Test]
    public function keys_are_sorted_and_whitespace_removed(): void
    {
        $input = '{ "b": 1, "a": {"d": 2, "c": [3, 4]} }';

        $this->assertSame('{"a":{"c":[3,4],"d":2},"b":1}', CanonicalJson::fromJsonString($input));
    }

    #[Test]
    public function an_empty_object_stays_an_object(): void
    {
        $this->assertSame('{"body":{}}', CanonicalJson::fromJsonString('{"body":{}}'));
    }

    #[Test]
    public function non_ascii_text_is_written_raw_not_escaped(): void
    {
        $this->assertSame('{"note":"سرمایہ"}', CanonicalJson::fromJsonString('{"note":"سرمایہ"}'));
    }

    #[Test]
    public function line_separators_are_not_escaped(): void
    {
        // Dart leaves U+2028 raw. PHP would escape it unless told not to.
        $raw = json_decode('" "');
        $this->assertSame("\"\u{2028}\"", CanonicalJson::encode($raw));
    }

    #[Test]
    public function floats_are_refused(): void
    {
        $this->expectException(InvalidArgumentException::class);

        CanonicalJson::fromJsonString('{"amount":1.5}');
    }
}
