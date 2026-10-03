/// For each author the relay is behind on, the first `seq` the relay lacks
/// (spec section 7.3, step 3: compare and repair).
///
/// [local] is this phone's version vector, and [relay] is the vector the
/// relay returned in its last reply. Only authors where the local vector is
/// higher are listed: the relay is missing records we hold. An author where
/// the relay is equal or ahead is left out, so it needs no upload.
///
/// The relay's vector is gap-aware (section 7.1). A relay that holds seq 1
/// and 3 reports 1, so the first missing seq is 2. The phone then re-uploads
/// everything from seq 2 on, and the gap is refilled without guessing.
Map<String, int> firstMissingSeqs({
  required Map<String, int> local,
  required Map<String, int> relay,
}) {
  final missing = <String, int>{};
  for (final entry in local.entries) {
    final relaySeq = relay[entry.key] ?? 0;
    if (relaySeq < entry.value) {
      missing[entry.key] = relaySeq + 1;
    }
  }
  return missing;
}
