<?php

namespace Tests\Unit;

use App\Support\CanonicalJson;
use App\Support\ReceivedRecord;
use PHPUnit\Framework\Attributes\Test;
use PHPUnit\Framework\TestCase;

/**
 * The relay checks the id of every record it stores (spec section 3). These
 * tests call parse() directly. The signature is not checked here: parse()
 * only reads the fields the relay needs, and it runs before any signature step.
 */
class ReceivedRecordTest extends TestCase
{
    /** Canonical text of a record with the given id; the other fields are fixed. */
    private function text(string $id): string
    {
        return CanonicalJson::encode((object) [
            'v' => 1,
            'id' => $id,
            'partnership' => '9bdb4685-0615-453d-a63a-4598e8fe1592',
            'author' => 'VmSPAhKyuAy4gr_6kPOSyVQUW4bojvHOSDKEv_K0SWU',
            'seq' => 2,
            'prevHash' => str_repeat('0', 64),
            'type' => 'invest',
            'body' => (object) ['amount' => 150000],
            'refersTo' => null,
            'note' => '',
            'time' => '2026-10-03T10:00:00Z',
            'sig' => 'x',
        ]);
    }

    #[Test]
    public function a_lowercase_uuid_v4_is_accepted(): void
    {
        $this->assertInstanceOf(
            ReceivedRecord::class,
            ReceivedRecord::parse($this->text('3f2a9c1e-7b4d-4e8a-9c2f-1d6b5a4e3f20')),
        );
    }

    #[Test]
    public function an_uppercase_uuid_is_refused(): void
    {
        $this->assertSame(
            'id must be a lowercase UUID v4',
            ReceivedRecord::parse($this->text('3F2A9C1E-7B4D-4E8A-9C2F-1D6B5A4E3F20')),
        );
    }

    #[Test]
    public function a_uuid_of_another_version_is_refused(): void
    {
        $this->assertSame(
            'id must be a lowercase UUID v4',
            ReceivedRecord::parse($this->text('3f2a9c1e-7b4d-1e8a-9c2f-1d6b5a4e3f20')),
        );
    }

    #[Test]
    public function a_uuid_with_the_wrong_variant_is_refused(): void
    {
        $this->assertSame(
            'id must be a lowercase UUID v4',
            ReceivedRecord::parse($this->text('3f2a9c1e-7b4d-4e8a-cc2f-1d6b5a4e3f20')),
        );
    }

    #[Test]
    public function text_that_is_not_a_uuid_is_refused(): void
    {
        $this->assertSame(
            'id must be a lowercase UUID v4',
            ReceivedRecord::parse($this->text('invest-2')),
        );
        $this->assertSame(
            'id must be a lowercase UUID v4',
            ReceivedRecord::parse($this->text("3f2a9c1e-7b4d-4e8a-9c2f-1d6b5a4e3f20\n")),
        );
    }
}
