import 'dart:convert';

import 'package:meta/meta.dart';
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

  /// This answer would be invalid under the settlement ordering rule (spec
  /// 6.7): an earlier settlement proposal is still unanswered. The app never
  /// writes a record it already knows is invalid, so nothing is written.
  /// Answer the earlier proposal first.
  answerEarlierFirst,

  /// An approve that would take effect needs the summary the user saw. The
  /// screen did not pass one, so nothing is written.
  consentNotShown,

  /// The partnership is not active yet (still pending, or the manager
  /// rejected it). Spec section 5: until the create is approved, nothing but
  /// the create (and the manager's own approve/reject of it) may be written.
  partnershipNotActive,

  /// The numbers changed since the user saw them, for example a sync made a
  /// settlement effective. Nothing is written. The result carries the new
  /// summary, and the screen asks again.
  summaryChanged,
}

/// The result of one write: the saved record, or the reason it was refused.
class WriteResult {
  const WriteResult.written(Record this.record)
    : refusal = null,
      latestSettlement = null,
      latestWithdrawal = null,
      latestReversal = null,
      latestBudget = null,
      latestRatio = null;

  const WriteResult.refused(
    WriteRefusal this.refusal, {
    this.latestSettlement,
    this.latestWithdrawal,
    this.latestReversal,
    this.latestBudget,
    this.latestRatio,
  }) : record = null;

  final Record? record;
  final WriteRefusal? refusal;

  /// The current settlement summary, set when the refusal is about a
  /// settlement summary ([WriteRefusal.summaryChanged] or
  /// [WriteRefusal.consentNotShown]). The screen shows these numbers.
  final SettlementConsent? latestSettlement;

  /// The current withdrawal summary, set in the same cases as [latestSettlement].
  final WithdrawalConsent? latestWithdrawal;

  /// The current reversal summary, set in the same cases as [latestSettlement].
  final ReversalConsent? latestReversal;

  /// The current budget summary, set in the same cases as [latestSettlement].
  final BudgetConsent? latestBudget;

  /// The current ratio summary, set in the same cases as [latestSettlement].
  final RatioConsent? latestRatio;
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
    @visibleForTesting Future<void> Function()? beforeSign,
  }) : _keys = keys,
       _store = store,
       _newId = newId ?? (() => const Uuid().v4()),
       _now = now ?? DateTime.now,
       _beforeSign = beforeSign ?? (() async {});

  final Ed25519KeyPair _keys;
  final RecordStore _store;
  final String Function() _newId;
  final DateTime Function() _now;

  // Test seam only: every real caller leaves this as a no-op. A test can
  // pass a hook that waits on a `Completer` it controls, so it can prove a
  // screen keeps its buttons disabled for the whole time a write is really
  // in flight — not just for one lucky frame — without depending on how
  // fast the real database happens to be.
  final Future<void> Function() _beforeSign;

  /// The partnership this writer writes for.
  final String partnership;

  String get _me => _keys.publicKeyBase64Url;

  /// Answers the proposal [targetId] with `approve` or `reject` (spec 5).
  ///
  /// Refuses, without writing, when the own chain is not known to be complete,
  /// or when this key has already answered validly. An invalid earlier answer
  /// does not count, so a new valid answer is allowed (spec 6.7).
  ///
  /// An approve of a settlement, withdrawal, reversal, budget or ratio
  /// proposal also needs the summary the user saw ([shownSettlement],
  /// [shownWithdrawal], [shownReversal], [shownBudget] or [shownRatio]). The
  /// summary is recomputed inside the write transaction. If it differs,
  /// nothing is written, and the result carries the new numbers (spec 6.7,
  /// consent).
  Future<WriteResult> answer(
    String targetId, {
    required bool approve,
    SettlementConsent? shownSettlement,
    WithdrawalConsent? shownWithdrawal,
    ReversalConsent? shownReversal,
    BudgetConsent? shownBudget,
    RatioConsent? shownRatio,
  }) async {
    // The gate reads the relay vector from the latest sync (spec 7.4, rule 2).
    final relayVector = await _store.relayVectorFor(partnership);
    if (relayVector == null) {
      return const WriteResult.refused(WriteRefusal.notSynced);
    }

    WriteRefusal? refusal;
    SettlementConsent? latestSettlement;
    WithdrawalConsent? latestWithdrawal;
    ReversalConsent? latestReversal;
    BudgetConsent? latestBudget;
    RatioConsent? latestRatio;
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
      final keys = validator.partnershipKeys ?? const <String>{};
      final decisions = decideApprovals(
        validator.usableRecords,
        partnershipKeys: keys,
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

      // Spec section 5: until the create is active, the only record anyone
      // may write is the manager's own answer to it. This is the one write
      // path in the app for anything other than that bootstrap create
      // (invest, sale, budget, withdrawal and ratio proposals are all
      // answered here too), so the gate belongs here, reading the same
      // `partnershipStatus` that decides effectiveness and the inbox.
      if (current.target.type != 'partnership_create' &&
          partnershipStatus(decisions) != DecisionStatus.active) {
        refusal = WriteRefusal.partnershipNotActive;
        return null;
      }

      // The builder reads my chain from [ledger], so the seq and prevHash
      // come from the saved records, never from the screen. It is unsigned
      // until the checks pass, and the summary only reads its numbers.
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

      // The app never writes a record it already knows is invalid. "Kept as
      // evidence" (spec 6.1, 6.7) is for records received from the other
      // partner, not for records this writer creates itself. Re-run the
      // ordering rule with the candidate as if it had just arrived, and
      // refuse if it would land in invalidResponses.
      if (current.target.type == 'settlement') {
        final withCandidate = decideApprovals([
          ...validator.usableRecords,
          unsigned,
        ], partnershipKeys: keys);
        final decided = withCandidate.firstWhere(
          (d) => d.target.id == targetId,
        );
        if (decided.invalidResponses.any((r) => r.id == unsigned.id)) {
          refusal = WriteRefusal.answerEarlierFirst;
          return null;
        }
      }

      // Optimistic check: the numbers the user saw must still be the numbers
      // core reports now (spec 6.7). A reject has no summary to check. When
      // the answer would have no effect there is no summary, so nothing is
      // checked, and the screen never offers that approve in the first place.
      if (approve && current.target.type == 'settlement') {
        final now = settlementConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          proposal: current.target,
          answer: unsigned,
        );
        latestSettlement = now;
        if (now == null) {
          if (shownSettlement != null) refusal = WriteRefusal.summaryChanged;
        } else if (shownSettlement == null) {
          refusal = WriteRefusal.consentNotShown;
        } else if (now != shownSettlement) {
          refusal = WriteRefusal.summaryChanged;
        }
        if (refusal != null) return null;
      }
      if (approve && current.target.type == 'withdraw_request') {
        final now = withdrawalConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          request: current.target,
          answer: unsigned,
        );
        latestWithdrawal = now;
        if (now == null) {
          if (shownWithdrawal != null) refusal = WriteRefusal.summaryChanged;
        } else if (shownWithdrawal == null) {
          refusal = WriteRefusal.consentNotShown;
        } else if (now != shownWithdrawal) {
          refusal = WriteRefusal.summaryChanged;
        }
        if (refusal != null) return null;
      }
      if (approve && current.target.type == 'reversal') {
        final now = reversalConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          reversal: current.target,
          answer: unsigned,
        );
        latestReversal = now;
        if (now == null) {
          if (shownReversal != null) refusal = WriteRefusal.summaryChanged;
        } else if (shownReversal == null) {
          refusal = WriteRefusal.consentNotShown;
        } else if (now != shownReversal) {
          refusal = WriteRefusal.summaryChanged;
        }
        if (refusal != null) return null;
      }
      if (approve && current.target.type == 'budget_proposal') {
        final now = budgetConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          proposal: current.target,
        );
        latestBudget = now;
        if (now == null) {
          if (shownBudget != null) refusal = WriteRefusal.summaryChanged;
        } else if (shownBudget == null) {
          refusal = WriteRefusal.consentNotShown;
        } else if (now != shownBudget) {
          refusal = WriteRefusal.summaryChanged;
        }
        if (refusal != null) return null;
      }
      if (approve && current.target.type == 'ratio_proposal') {
        final now = ratioConsent(
          validator.usableRecords,
          partnershipKeys: keys,
          proposal: current.target,
        );
        latestRatio = now;
        if (now == null) {
          if (shownRatio != null) refusal = WriteRefusal.summaryChanged;
        } else if (shownRatio == null) {
          refusal = WriteRefusal.consentNotShown;
        } else if (now != shownRatio) {
          refusal = WriteRefusal.summaryChanged;
        }
        if (refusal != null) return null;
      }

      // Every check has passed: this write will really happen. A test can
      // hold this open; a real run passes straight through.
      await _beforeSign();

      final signed = await signRecord(unsigned, _keys);
      return canonicalJson(signed.toJson());
    });

    if (text == null) {
      return WriteResult.refused(
        refusal!,
        latestSettlement: latestSettlement,
        latestWithdrawal: latestWithdrawal,
        latestReversal: latestReversal,
        latestBudget: latestBudget,
        latestRatio: latestRatio,
      );
    }
    return WriteResult.written(
      Record.fromJson(jsonDecode(text) as Map<String, dynamic>),
    );
  }

  /// The display time in whole seconds, UTC, as the spec example shows (spec 3).
  static String _timeText(DateTime moment) =>
      '${moment.toUtc().toIso8601String().split('.').first}Z';
}
