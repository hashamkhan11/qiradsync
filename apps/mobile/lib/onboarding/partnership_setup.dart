import 'package:qirad_core/qirad_core.dart';
import 'package:uuid/uuid.dart';

import '../storage/record_store.dart';

/// Starts a new partnership on the investor's phone (spec 2.1, steps 1 and 2).
///
/// The phone makes a random partnership id, pins both keys, then writes and
/// stores the `partnership_create`. Returns the id, which the join code carries.
///
/// The create is the first record, so it has seq 1 and a prev_hash of 64 zeros.
Future<String> createPartnership({
  required Ed25519KeyPair investorKeys,
  required String managerKey,
  required int investorPercent,
  required RecordStore store,
}) async {
  final investorKey = investorKeys.publicKeyBase64Url;

  // A key typed by hand must be the one the manager shows. A wrong spelling
  // would pin a key that never signs, so the partnership would stall.
  if (!isCanonicalPublicKey(managerKey)) {
    throw ArgumentError.value(managerKey, 'managerKey', 'not a valid key');
  }
  if (managerKey == investorKey) {
    throw ArgumentError.value(
      managerKey,
      'managerKey',
      'this is your own key; the manager must use another phone',
    );
  }
  // Both partners share in the profit, so each share is 1 to 99 (spec 5).
  // The manager's share is the rest, which keeps the sum at 100.
  RangeError.checkValueInInterval(investorPercent, 1, 99, 'investorPercent');

  final id = const Uuid().v4();

  final unsigned = Record(
    v: 1,
    id: id,
    partnership: id,
    author: investorKey,
    seq: 1,
    prevHash: '0' * 64,
    type: 'partnership_create',
    body: {
      'investor': investorKey,
      'manager': managerKey,
      'ratio': {'investor': investorPercent, 'manager': 100 - investorPercent},
      'currency': 'PKR',
    },
    refersTo: null,
    note: '',
    // Display only (spec 3). Whole seconds, UTC, as the spec's example shows.
    time: '${DateTime.now().toUtc().toIso8601String().split('.').first}Z',
    sig: '',
  );
  final signed = await signRecord(unsigned, investorKeys);
  // Pins and create are saved together, or not at all (see startPartnership).
  final outcome = await store.startPartnership(
    id: id,
    investorKey: investorKey,
    managerKey: managerKey,
    createText: canonicalJson(signed.toJson()),
  );
  if (outcome != ReceiveOutcome.accepted) {
    throw StateError('the new partnership was refused: $outcome');
  }
  return id;
}
