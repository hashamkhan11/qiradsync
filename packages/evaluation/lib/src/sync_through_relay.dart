import 'package:qirad_core/qirad_core.dart';

import 'relay_sim.dart';

/// Runs one device's sync loop against [relay]: query it, upload whatever of
/// [ownKey]'s own records it turns out to be missing, and repeat until
/// nothing of this device's own is missing or [maxRepairRounds] upload
/// attempts have been made — the same shape as the real client's
/// `SyncRunner._runOnce` (apps/mobile/lib/sync/sync_runner.dart), reused here
/// instead of a second, separately maintained copy of the same logic.
///
/// Two differences from the real client, both simulation simplifications
/// (see docs/evaluation/README.md's "Simulation simplifications"), not
/// protocol differences:
///
///  - Upload candidates are restricted to [ownKey]'s own records. The real
///    client re-sends every saved text every call, "because a smaller
///    candidate list would be only a bandwidth shortcut" (that file's own
///    comment) — true here too; this simulation just takes the shortcut,
///    since it never needs to recover someone else's lost upload.
///  - What the relay "already has" is read fresh from THIS call's reply
///    every time ([RelaySim.sync]'s own return value), never assumed from an
///    earlier round. Trusting a remembered vector instead is exactly the bug
///    spec 7.3 forbids (docs/decisions.md, "Sync loop must not trust a
///    cached relay vector") — the same rule applies to this loop.
///
/// [ownTextsFrom] must return this device's own signed record texts starting
/// at the given seq (inclusive), in ascending seq order. It may return fewer
/// than are actually missing (the generator uses this to model relay delay
/// as a holdback on upload — a record it is not yet time to send is simply
/// left out); an empty list means nothing is ready yet, and the loop stops
/// rather than spending repair rounds retrying a condition that has not
/// changed.
///
/// [reorder], when given, replaces one call's received batch (`records` +
/// `conflicts`) with its own return value before the texts are fed to
/// [validator] — the hook the `stress`-only "shuffled batch" option uses to
/// deliberately feed records out of the relay's otherwise guaranteed
/// per-author order, exercising the validator's chain-gap buffer.
Future<RelaySyncReply> syncOwnRecords({
  required RelaySim relay,
  required Validator validator,
  required String ownKey,
  required List<String> Function(int fromSeq) ownTextsFrom,
  int maxRepairRounds = 3,
  List<String> Function(List<String> texts)? reorder,
}) async {
  Future<RelaySyncReply> roundTrip(List<String> uploads) async {
    final reply = relay.sync(
      clientVector: validator.ledger.versionVector(),
      uploads: uploads,
    );
    var received = [...reply.records, ...reply.conflicts];
    if (reorder != null) received = reorder(received);
    for (final text in received) {
      await validator.receiveText(text);
    }
    return reply;
  }

  var reply = await roundTrip(const []);
  for (var round = 0; round < maxRepairRounds; round++) {
    final fromSeq = firstMissingSeqs(
      local: validator.ledger.versionVector(),
      relay: reply.vector,
    )[ownKey];
    if (fromSeq == null) return reply;
    final uploads = ownTextsFrom(fromSeq);
    if (uploads.isEmpty) return reply;
    reply = await roundTrip(uploads);
  }
  return reply;
}
