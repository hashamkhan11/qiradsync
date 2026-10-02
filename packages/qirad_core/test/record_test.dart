import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

Map<String, dynamic> _sampleJson() => {
  'v': 1,
  'id': '11111111-1111-4111-8111-111111111111',
  'partnership': '11111111-1111-4111-8111-111111111111',
  'author': 'author-pubkey-base64url',
  'seq': 1,
  'prevHash': '0' * 64,
  'type': 'partnership_create',
  'body': {'name': 'Test Mudaraba'},
  'refersTo': null,
  'note': '',
  'time': '2026-10-02T10:15:00Z',
  'sig': 'sig-base64url',
};

void main() {
  group('Record', () {
    test('fromJson reads every field from spec section 3', () {
      final record = Record.fromJson(_sampleJson());

      expect(record.v, 1);
      expect(record.id, '11111111-1111-4111-8111-111111111111');
      expect(record.partnership, '11111111-1111-4111-8111-111111111111');
      expect(record.author, 'author-pubkey-base64url');
      expect(record.seq, 1);
      expect(record.prevHash, '0' * 64);
      expect(record.type, 'partnership_create');
      expect(record.body, {'name': 'Test Mudaraba'});
      expect(record.refersTo, isNull);
      expect(record.note, '');
      expect(record.time, '2026-10-02T10:15:00Z');
      expect(record.sig, 'sig-base64url');
    });

    test('toJson then fromJson round-trips to an identical record', () {
      final original = Record.fromJson(_sampleJson());
      final roundTripped = Record.fromJson(original.toJson());

      expect(roundTripped.toJson(), original.toJson());
    });

    test('refersTo can be a non-null id, for records that target another', () {
      final json = _sampleJson();
      json['refersTo'] = '22222222-2222-4222-8222-222222222222';

      final record = Record.fromJson(json);

      expect(record.refersTo, '22222222-2222-4222-8222-222222222222');
    });
  });
}
