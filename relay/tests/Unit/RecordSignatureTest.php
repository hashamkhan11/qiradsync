<?php

namespace Tests\Unit;

use App\Support\RecordSignature;
use PHPUnit\Framework\Attributes\Test;
use PHPUnit\Framework\TestCase;

class RecordSignatureTest extends TestCase
{
    /** The record signed in Dart, from packages/qirad_core (see the shared vector). */
    private function canonical(): string
    {
        return json_decode(
            file_get_contents(__DIR__.'/../Fixtures/record_vector.json'),
            true,
            512,
            JSON_THROW_ON_ERROR,
        )['canonical'];
    }

    #[Test]
    public function a_record_signed_in_dart_verifies_in_php(): void
    {
        $this->assertTrue(RecordSignature::verify($this->canonical()));
    }

    #[Test]
    public function a_changed_amount_fails(): void
    {
        $tampered = str_replace('"amount":150000', '"amount":150001', $this->canonical());

        $this->assertFalse(RecordSignature::verify($tampered));
    }

    #[Test]
    public function a_changed_urdu_note_fails(): void
    {
        $tampered = str_replace('سرمایہ', 'سرمایا', $this->canonical());

        $this->assertFalse(RecordSignature::verify($tampered));
    }

    #[Test]
    public function a_different_author_key_fails(): void
    {
        $author = json_decode($this->canonical())->author;
        $other = str_repeat('A', 43);
        $tampered = str_replace('"author":"'.$author.'"', '"author":"'.$other.'"', $this->canonical());

        $this->assertFalse(RecordSignature::verify($tampered));
    }

    #[Test]
    public function a_malformed_signature_fails(): void
    {
        $sig = json_decode($this->canonical())->sig;
        $tampered = str_replace('"sig":"'.$sig.'"', '"sig":"not base64!"', $this->canonical());

        $this->assertFalse(RecordSignature::verify($tampered));
    }

    #[Test]
    public function input_that_is_not_an_object_fails(): void
    {
        $this->assertFalse(RecordSignature::verify('[1,2,3]'));
        $this->assertFalse(RecordSignature::verify('not json'));
        $this->assertFalse(RecordSignature::verify('{}'));
    }
}
