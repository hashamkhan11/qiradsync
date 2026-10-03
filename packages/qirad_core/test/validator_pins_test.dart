import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

void main() {
  late Ed25519KeyPair investor;
  late Ed25519KeyPair manager;
  late Ed25519KeyPair attacker;

  setUp(() async {
    investor = await generateEd25519KeyPair();
    manager = await generateEd25519KeyPair();
    attacker = await generateEd25519KeyPair();
  });

  /// A signed partnership_create. [author] signs it, and the body names the
  /// given investor and manager keys.
  Future<String> create({
    required Ed25519KeyPair author,
    required String investorKey,
    required String managerKey,
    String id = 'p1',
  }) async {
    final unsigned = Record(
      v: 1,
      id: id,
      partnership: id,
      author: author.publicKeyBase64Url,
      seq: 1,
      prevHash: '0' * 64,
      type: 'partnership_create',
      body: {
        'investor': investorKey,
        'manager': managerKey,
        'ratio': {'investor': 60, 'manager': 40},
        'currency': 'PKR',
      },
      refersTo: null,
      note: '',
      time: '2026-10-03T10:00:00Z',
      sig: '',
    );
    return canonicalJson((await signRecord(unsigned, author)).toJson());
  }

  Validator pinned() => Validator(
    pinnedInvestorKey: investor.publicKeyBase64Url,
    pinnedManagerKey: manager.publicKeyBase64Url,
  );

  test(
    'a forged create arriving first is rejected, then the real one is accepted',
    () async {
      final validator = pinned();
      // The attacker signs a create with their own key, naming themselves as
      // investor and the real manager. The signature is valid, so only the pin
      // can refuse it.
      final forged = await create(
        author: attacker,
        investorKey: attacker.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );
      final real = await create(
        author: investor,
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );

      expect(
        await validator.receiveText(forged),
        ReceiveOutcome.rejectedMembership,
      );
      expect(validator.ledger.records, isEmpty);

      expect(await validator.receiveText(real), ReceiveOutcome.accepted);
      expect(validator.ledger.records.map((r) => r.author), [
        investor.publicKeyBase64Url,
      ]);
      expect(validator.partnershipKeys, {
        investor.publicKeyBase64Url,
        manager.publicKeyBase64Url,
      });
    },
  );

  test('a create that names another manager is rejected', () async {
    final validator = pinned();
    final otherManager = await generateEd25519KeyPair();
    final wrongManager = await create(
      author: investor,
      investorKey: investor.publicKeyBase64Url,
      managerKey: otherManager.publicKeyBase64Url,
    );

    expect(
      await validator.receiveText(wrongManager),
      ReceiveOutcome.rejectedMembership,
    );
    expect(validator.ledger.records, isEmpty);
  });

  test(
    'a create signed by the manager but naming the investor is rejected',
    () async {
      final validator = pinned();
      // The manager signs a create that names the real investor and manager.
      // The author is not the pinned investor, so it is refused.
      final byManager = await create(
        author: manager,
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );

      expect(
        await validator.receiveText(byManager),
        ReceiveOutcome.rejectedMembership,
      );
      expect(validator.ledger.records, isEmpty);
    },
  );

  test(
    'without pins, any valid create is still accepted (core rule tests)',
    () async {
      final forged = await create(
        author: attacker,
        investorKey: attacker.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
      );

      expect(
        await Validator.unpinnedForTesting().receiveText(forged),
        ReceiveOutcome.accepted,
      );
    },
  );
}
