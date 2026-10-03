import 'package:qirad_core/qirad_core.dart';

import '../storage/record_store.dart';
import 'relay_client.dart';

/// The result of one sync run.
class SyncResult {
  const SyncResult({required this.complete, required this.repairRounds});

  /// True when the relay's own vector matched ours for every author.
  /// False means the relay kept failing to store records after the repair
  /// rounds. The app then stops and shows a partial result. It never hangs.
  final bool complete;

  /// How many repair uploads were needed (spec 7.3 step 3).
  final int repairRounds;
}

/// One sync run for one partnership (spec 7.3, steps 1 to 5).
///
/// The run sends every saved text, then checks the relay's freshly returned
/// vector. If the relay is behind for any author, it re-uploads what the
/// relay is missing. It repeats for at most [maxRepairRounds] rounds. Every
/// returned record goes through the store's validator, so nothing from the
/// relay is trusted.
class SyncRunner {
  SyncRunner({
    required this.store,
    required this.relay,
    required this.token,
    this.maxRepairRounds = 3,
  });

  final RecordStore store;
  final RelayClient relay;

  /// The device's bearer token. Registration (spec 7.2) gives it to us.
  final String token;

  final int maxRepairRounds;

  Future<SyncResult> run(String partnership) async {
    // Step 1: every saved text is a candidate. The relay skips duplicates
    // and reports them as `already`. This is simple and always correct; a
    // smaller candidate list would be only a bandwidth shortcut (spec 7.3).
    final candidates = await store.savedTexts(partnership);
    var reply = await _call(partnership, candidates);
    await _receive(partnership, reply);

    for (var round = 0; ; round++) {
      // Step 3: compare with the relay's fresh vector, using our vector as it
      // is now (it may have grown from the records just received).
      final missing = firstMissingSeqs(
        local: store.versionVector(partnership),
        relay: reply.vector,
      );
      if (missing.isEmpty) {
        return SyncResult(complete: true, repairRounds: round);
      }
      if (round == maxRepairRounds) {
        return SyncResult(complete: false, repairRounds: round);
      }

      // Repair: upload from the first missing seq of each author onward.
      // The relay refills any gap it has, because it stores what it is sent.
      final uploads = await _textsFrom(partnership, missing);
      reply = await _call(partnership, uploads);
      await _receive(partnership, reply);
    }
  }

  Future<SyncReply> _call(String partnership, List<String> records) {
    return relay.sync(
      partnership: partnership,
      token: token,
      vector: store.versionVector(partnership),
      records: records,
    );
  }

  /// Step 4: every returned record and conflict goes through the validator.
  /// The store keeps the valid ones. The relay's `accepted` list is not read,
  /// because the relay's word is not a basis for any decision.
  Future<void> _receive(String partnership, SyncReply reply) async {
    for (final text in [...reply.records, ...reply.conflicts]) {
      await store.receive(text);
    }
  }

  /// The saved texts that the relay is missing, author by author, in seq
  /// order. Authors are sorted so the upload is the same on every run.
  Future<List<String>> _textsFrom(
    String partnership,
    Map<String, int> missing,
  ) async {
    final texts = <String>[];
    final authors = missing.keys.toList()..sort();
    for (final author in authors) {
      texts.addAll(
        await store.savedTextsFrom(
          partnership,
          author: author,
          fromSeq: missing[author]!,
        ),
      );
    }
    return texts;
  }
}
