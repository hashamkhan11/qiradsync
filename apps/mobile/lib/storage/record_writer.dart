import 'dart:convert';

import 'package:qirad_core/qirad_core.dart';
import 'package:uuid/uuid.dart';

import 'record_store.dart';

/// Why the writer refused to write (spec 7.4).
enum WriteRefusal {
  /// This install has never synced the partnership, so it cannot know its own
  /// chain is complete.
  notSynced,

  /// The relay holds a higher seq for this key than the phone does. The phone
  /// is missing its own records, so it syncs first.
  chainBehindRelay,

  /// No pending proposal with this id that needs an answer from this key.
  notAnswerable,

  /// The other partner already answered this proposal validly.
  alreadyDecided,

  /// This key already answered this proposal validly (spec 7.4, rule 3).
  alreadyAnswered,
}

/// The result of one write: the saved record, or the reason it was refused.
class WriteResult {
  const WriteResult.written(Record this.record) : refusal = null;

  const WriteResult.refused(WriteRefusal this.refusal) : record = null;

  final Record? record;
  final WriteRefusal? refusal;
}

/// The only code that writes this phone's own records (spec 7.4).
///
/// It holds the private key. Screens get a [RecordWriter] and can call
/// [answer], but they never see the key. Each write goes through
/// [RecordStore.appendWith], so reading the chain, signing and saving happen
/// in one transaction and one queue. Two writes cannot pick the same seq.
class RecordWriter {
  RecordWriter({
    required Ed25519KeyPair keys,
    required this.partnership,
    required RecordStore store,
    String Function()? newId,
    DateTime Function()? now,
  }) : _keys = keys,
       _store = store,
       _newId = newId ?? (() => const Uuid().v4()),
       _now = now ?? DateTime.now;

  final Ed25519KeyPair _keys;
  final RecordStore _store;
  final String Function() _newId;
  final DateTime Function() _now;

  /// The partnership this writer writes for.
  final String partnership;

  String get _me => _keys.publicKeyBase64Url;

  /// Answers the proposal [targetId] with `approve` or `reject` (spec 5).
  ///
  /// Refuses, without writing, when the own chain is not known to be complete,
  /// or when this key has already answered validly. An invalid earlier answer
  /// does not count, so a new valid answer is allowed (spec 6.7).
  Future<WriteResult> answer(String targetId, {required bool approve}) async {
    // The gate reads the relay vector from the latest sync (spec 7.4, rule 2).
    final relayVector = await _store.relayVectorFor(partnership);
    if (relayVector == null) {
      return const WriteResult.refused(WriteRefusal.notSynced);
    }

    WriteRefusal? refusal;
    final text = await _store.appendWith(partnership, (texts) async {
      final ledger = [
        for (final text in texts)
          Record.fromJson(jsonDecode(text) as Map<String, dynamic>),
      ];

      final localTop = ledger
          .where((r) => r.author == _me)
          .fold<int>(0, (top, r) => r.seq > top ? r.seq : top);
      if ((relayVector[_me] ?? 0) > localTop) {
        refusal = WriteRefusal.chainBehindRelay;
        return null;
      }

      final validator = _store.validatorFor(partnership);
      final decisions = decideApprovals(
        validator.usableRecords,
        partnershipKeys: validator.partnershipKeys ?? const {},
      );
      final decision = decisions.where((d) => d.target.id == targetId);
      if (decision.isEmpty || decision.single.target.author == _me) {
        refusal = WriteRefusal.notAnswerable;
        return null;
      }
      final current = decision.single;
      if (current.hasValidResponseFrom(_me)) {
        refusal = WriteRefusal.alreadyAnswered;
        return null;
      }
      if (current.status != DecisionStatus.pending) {
        refusal = WriteRefusal.alreadyDecided;
        return null;
      }

      // The builder reads my chain from [ledger], so the seq and prevHash
      // come from the saved records, never from the screen.
      final unsigned = buildRecord(
        ledger: ledger,
        author: _me,
        partnership: partnership,
        id: _newId(),
        type: approve ? 'approve' : 'reject',
        body: const {},
        time: _timeText(_now()),
        refersTo: targetId,
      );
      final signed = await signRecord(unsigned, _keys);
      return canonicalJson(signed.toJson());
    });

    if (text == null) return WriteResult.refused(refusal!);
    return WriteResult.written(
      Record.fromJson(jsonDecode(text) as Map<String, dynamic>),
    );
  }

  /// The display time in whole seconds, UTC, as the spec example shows (spec 3).
  static String _timeText(DateTime moment) =>
      '${moment.toUtc().toIso8601String().split('.').first}Z';
}
