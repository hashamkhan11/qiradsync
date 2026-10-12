import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';
import 'support/test_ids.dart';

void main() {
  test(
    'a record rejected because the partnership was not yet known is '
    'accepted once the create arrives and the same record is redelivered',
    () async {
      // This is the real-app side of the race the evaluation generator's
      // direct-delivery queue once hit by accident: a device's `invest`
      // (seq 2) reaching the other device before that device has learned
      // the partnership from `partnership_create` (seq 1). The bootstrap
      // branch of `Validator._passesMembership` rejects such a record
      // outright rather than buffering it, so recovery has to come from
      // the sync layer re-sending it later, not from the validator itself.
      final investor = await generateEd25519KeyPair();
      final manager = await generateEd25519KeyPair();
      final partnershipId = testId('p1');

      final unsignedCreate = Record(
        v: 1,
        id: partnershipId,
        partnership: partnershipId,
        author: investor.publicKeyBase64Url,
        seq: 1,
        prevHash: '0' * 64,
        type: 'partnership_create',
        body: {
          'investor': investor.publicKeyBase64Url,
          'manager': manager.publicKeyBase64Url,
          'ratio': {'investor': 60, 'manager': 40},
          'currency': 'PKR',
        },
        refersTo: null,
        note: '',
        time: '2026-10-03T10:00:00Z',
        sig: '',
      );
      final create = await signRecord(unsignedCreate, investor);

      final unsignedInvest = Record(
        v: 1,
        id: testId('invest1'),
        partnership: partnershipId,
        author: investor.publicKeyBase64Url,
        seq: 2,
        prevHash: recordHash(create.toJson()),
        type: 'invest',
        body: const {'amount': 500000},
        refersTo: null,
        note: '',
        time: '2026-10-03T11:00:00Z',
        sig: '',
      );
      final invest = await signRecord(unsignedInvest, investor);

      final createText = canonicalJson(create.toJson());
      final investText = canonicalJson(invest.toJson());

      final managerValidator = Validator(
        pinnedInvestorKey: investor.publicKeyBase64Url,
        pinnedManagerKey: manager.publicKeyBase64Url,
      );

      // The invest arrives first (the race) and is rejected, not buffered.
      expect(
        await managerValidator.receiveText(investText),
        ReceiveOutcome.rejectedMembership,
      );
      expect(managerValidator.ledger.records, isEmpty);

      // A rejected record never advances the version vector, so the next
      // sync round still reports this author's seq 2 as not held — which
      // is exactly what makes the relay send it again (spec 7.1/7.3).
      expect(managerValidator.ledger.versionVector(), isEmpty);

      // The create arrives on a later sync.
      expect(
        await managerValidator.receiveText(createText),
        ReceiveOutcome.accepted,
      );
      expect(managerValidator.ledger.versionVector(), {
        investor.publicKeyBase64Url: 1,
      });

      // The relay re-sends the same invest text on the next sync, since
      // the device's vector still shows it missing. This time it is
      // accepted: the partnership is now known.
      expect(
        await managerValidator.receiveText(investText),
        ReceiveOutcome.accepted,
      );
      expect(managerValidator.ledger.records.map((r) => r.type), [
        'partnership_create',
        'invest',
      ]);
      expect(managerValidator.ledger.versionVector(), {
        investor.publicKeyBase64Url: 2,
      });
    },
  );
}
