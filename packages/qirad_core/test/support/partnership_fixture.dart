import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';
import 'test_ids.dart';

/// Signs a growing chain of records for one author, tracking `seq` and
/// `prevHash` the way a real device would.
class ChainAuthor {
  final Ed25519KeyPair keyPair;
  int seq = 0;
  String prevHash = '0' * 64;
  int _counter = 0;

  ChainAuthor(this.keyPair);

  String get key => keyPair.publicKeyBase64Url;

  Future<Record> next({
    required String partnership,
    required String type,
    Map<String, dynamic> body = const {},
    String note = '',
    String? refersTo,
    String? id,
  }) async {
    seq += 1;
    _counter += 1;
    final unsigned = Record(
      v: 1,
      // A partnership_create's id must equal its `partnership` (spec 3), so
      // tests pass it explicitly when they need it.
      id: id ?? testId('${key.substring(0, 8)}-rec-$_counter'),
      partnership: partnership,
      author: key,
      seq: seq,
      prevHash: prevHash,
      type: type,
      body: body,
      refersTo: refersTo,
      note: note,
      time: '2026-10-02T10:00:00Z',
      sig: '',
    );
    final signed = await signRecord(unsigned, keyPair);
    prevHash = recordHash(signed.toJson());
    return signed;
  }
}

/// A validator with a partnership bootstrapped but not approved yet: the
/// investor's `partnership_create` (seq 1) has been accepted, so
/// `partnershipKeys` is known, but the manager has not answered it.
///
/// Spec section 5: until the create is active, nothing else is effective,
/// and this app refuses to write anything else. Use this fixture only for
/// tests about that pending (or, after a reject, dead) state itself — every
/// other test wants [setUpPartnership], a real active partnership.
Future<(Validator, ChainAuthor, ChainAuthor, String)>
setUpUnapprovedPartnership() async {
  final investor = ChainAuthor(await generateEd25519KeyPair());
  final manager = ChainAuthor(await generateEd25519KeyPair());
  final partnershipId = testId('partnership-1');
  final validator = Validator.unpinnedForTesting();

  final create = await investor.next(
    partnership: partnershipId,
    type: 'partnership_create',
    id: partnershipId,
    body: {
      'investor': investor.key,
      'manager': manager.key,
      'ratio': {'investor': 60, 'manager': 40},
      'currency': 'PKR',
    },
  );
  expect(await validator.receiveText(canonicalJson(create.toJson())), ReceiveOutcome.accepted);

  return (validator, investor, manager, partnershipId);
}

/// A validator with a real, active partnership: the investor's
/// `partnership_create` (seq 1), plus the manager's `approve` of it (seq 1
/// on the manager's own chain). `partnershipKeys` is known and both
/// partners' other records can take effect (spec section 5).
Future<(Validator, ChainAuthor, ChainAuthor, String)> setUpPartnership() async {
  final (validator, investor, manager, partnershipId) =
      await setUpUnapprovedPartnership();

  final approve = await manager.next(
    partnership: partnershipId,
    type: 'approve',
    refersTo: partnershipId,
  );
  expect(await validator.receiveText(canonicalJson(approve.toJson())), ReceiveOutcome.accepted);

  return (validator, investor, manager, partnershipId);
}
