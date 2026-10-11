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

  /// This key is not the role spec section 5 allows to author this record
  /// type (for example the manager trying to `invest`, or either partner
  /// trying to request a capital withdrawal when they are the manager). The
  /// validator would refuse this record outright on receive, so the writer
  /// refuses it here instead of ever signing it.
  wrongRole,

  /// An `expense`'s `refersTo` does not name a budget that is both approved
  /// and granted to this key (spec section 5, 6.4). A budget proposed for
  /// the other partner, or one still pending, is not spendable by this key.
  noEffectiveBudget,

  /// A `reversal`'s target is not one of the types spec section 5 allows to
  /// be reversed (`invest`, `sale`, `expense`, `withdraw_request`), or the
  /// target is not held on this phone at all.
  notReversible,

  /// A settlement's natural cut (the phone's current chain vector) would
  /// equal the last effective settlement's cut: nothing has happened since
  /// then for either partner, so there is nothing new to settle.
  emptyCut,

  /// An `expense`'s amount is more than this key's budget has left right
  /// now (spec 7.4, decision 2026-10-11). Spec 6.4's "flagged and excluded"
  /// rule is for an over-budget expense *received* from the other partner —
  /// this phone never creates one, so [proposeExpense] refuses it here
  /// instead. [WriteResult.budgetLeft] carries the amount actually left.
  overBudget,
}

/// The result of one write: the saved record, or the reason it was refused.
class WriteResult {
  const WriteResult.written(Record this.record)
    : refusal = null,
      latestSettlement = null,
      latestWithdrawal = null,
      latestReversal = null,
      latestBudget = null,
      latestRatio = null,
      budgetLeft = null;

  const WriteResult.refused(
    WriteRefusal this.refusal, {
    this.latestSettlement,
    this.latestWithdrawal,
    this.latestReversal,
    this.latestBudget,
    this.latestRatio,
    this.budgetLeft,
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

  /// The amount actually left in the budget, set only for
  /// [WriteRefusal.overBudget]. The screen can show "Over budget: X left"
  /// without recomputing it itself.
  final int? budgetLeft;
}

/// Maps [qirad_core]'s [AnswerEligibilityRefusal] to this class's own
/// [WriteRefusal]. A switch expression, not a switch statement with a
/// default: adding a reason to the core enum without adding a case here
/// fails to compile, instead of silently falling through.
WriteRefusal _fromEligibility(AnswerEligibilityRefusal reason) =>
    switch (reason) {
      AnswerEligibilityRefusal.notAnswerable => WriteRefusal.notAnswerable,
      AnswerEligibilityRefusal.alreadyAnswered => WriteRefusal.alreadyAnswered,
      AnswerEligibilityRefusal.alreadyDecided => WriteRefusal.alreadyDecided,
      AnswerEligibilityRefusal.partnershipNotActive =>
        WriteRefusal.partnershipNotActive,
    };

/// Maps [qirad_core]'s [AnswerConsentRefusal] to [WriteRefusal] (see
/// [_fromEligibility]).
WriteRefusal _fromConsent(AnswerConsentRefusal reason) => switch (reason) {
  AnswerConsentRefusal.answerEarlierFirst => WriteRefusal.answerEarlierFirst,
  AnswerConsentRefusal.consentNotShown => WriteRefusal.consentNotShown,
  AnswerConsentRefusal.summaryChanged => WriteRefusal.summaryChanged,
};

/// Maps [qirad_core]'s [ProposalRefusal] to [WriteRefusal] (see
/// [_fromEligibility]).
WriteRefusal _fromProposal(ProposalRefusal reason) => switch (reason) {
  ProposalRefusal.wrongRole => WriteRefusal.wrongRole,
  ProposalRefusal.noEffectiveBudget => WriteRefusal.noEffectiveBudget,
  ProposalRefusal.overBudget => WriteRefusal.overBudget,
  ProposalRefusal.notReversible => WriteRefusal.notReversible,
  ProposalRefusal.emptyCut => WriteRefusal.emptyCut,
};

/// The only code that writes this phone's own records (spec 7.4).
///
/// It holds the private key. Screens get a [RecordWriter] and can call
/// [answer], but they never see the key. Each write goes through
/// [RecordStore.appendWith], so reading the chain, signing and saving happen
/// in one transaction and one queue. Two writes cannot pick the same seq.
///
/// This class owns the lock, the transaction, the relay-sync gate and the
/// signing. Every other rule — who may author what, whether a budget or
/// reversal target is valid, whether an answer is in order and its numbers
/// still match — is decided once, in `qirad_core` ([answerEligibility],
/// [answerConsent], [proposalRefusal]), so the evaluation harness's workload
/// generator can call the exact same functions instead of a second copy.
class RecordWriter {
  // Private: the cache in AppDependencies is what stops two RecordWriter
  // instances existing for one partnership (spec 7.4), but a cache only
  // protects callers that go through it. Hiding this constructor means the
  // *only* way to build a real one is `RecordWriter.forPartnership`, which
  // `AppDependencies.writerFor` calls and nothing else needs to.
  RecordWriter._({
    required Ed25519KeyPair keys,
    required this.partnership,
    required RecordStore store,
    String Function()? newId,
    DateTime Function()? now,
    Future<void> Function()? beforeSign,
  }) : _keys = keys,
       _store = store,
       _newId = newId ?? (() => const Uuid().v4()),
       _now = now ?? DateTime.now,
       _beforeSign = beforeSign ?? (() async {});

  /// The one production entry point. No test hooks: a writer built this way
  /// always uses real ids, the real clock, and a real signature, so nothing
  /// outside a test can accidentally slip in a fake one.
  factory RecordWriter.forPartnership({
    required Ed25519KeyPair keys,
    required String partnership,
    required RecordStore store,
  }) => RecordWriter._(keys: keys, partnership: partnership, store: store);

  /// Test-only: the same writer, but with the seams tests need — a fake id
  /// generator, a fake clock, or (most often) [beforeSign] to hold a write
  /// open so a test can check a screen's state while one is in flight.
  @visibleForTesting
  factory RecordWriter.forTesting({
    required Ed25519KeyPair keys,
    required String partnership,
    required RecordStore store,
    String Function()? newId,
    DateTime Function()? now,
    Future<void> Function()? beforeSign,
  }) => RecordWriter._(
    keys: keys,
    partnership: partnership,
    store: store,
    newId: newId,
    now: now,
    beforeSign: beforeSign,
  );

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
      if (!_store.isCaughtUpWithRelay(
        relayVector: relayVector,
        me: _me,
        localTop: localTop,
      )) {
        refusal = WriteRefusal.chainBehindRelay;
        return null;
      }

      final validator = _store.validatorFor(partnership);

      // Cheap checks first, before a candidate answer record exists (spec
      // 5, 6.7, 7.4): not-answerable, already-decided, already-answered,
      // partnership-not-active.
      final eligibility = answerEligibility(
        targetId: targetId,
        me: _me,
        validator: validator,
      );
      if (eligibility != null) {
        refusal = _fromEligibility(eligibility);
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

      // The app never writes a record it already knows is invalid: the
      // settlement ordering rule, and (for an approve) whether the numbers
      // the user saw still match (spec 6.7, consent).
      final consent = answerConsent(
        targetId: targetId,
        approve: approve,
        candidate: unsigned,
        validator: validator,
        shownSettlement: shownSettlement,
        shownWithdrawal: shownWithdrawal,
        shownReversal: shownReversal,
        shownBudget: shownBudget,
        shownRatio: shownRatio,
      );
      if (consent != null) {
        refusal = _fromConsent(consent.reason);
        latestSettlement = consent.latestSettlement;
        latestWithdrawal = consent.latestWithdrawal;
        latestReversal = consent.latestReversal;
        latestBudget = consent.latestBudget;
        latestRatio = consent.latestRatio;
        return null;
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

  /// Proposes `invest`: adds capital (spec section 5). Investor only.
  Future<WriteResult> proposeInvest({required int amount}) =>
      _propose(type: 'invest', bodyOf: (_, _, _) => {'amount': amount});

  /// Proposes `sale`: adds income (spec section 5). Manager only.
  Future<WriteResult> proposeSale({required int amount}) =>
      _propose(type: 'sale', bodyOf: (_, _, _) => {'amount': amount});

  /// Proposes `expense`: removes money, drawn from [budgetId] (spec section
  /// 5, 6.4). Manager only, and only from a budget this key is the grantee
  /// of — the same list [effectiveBudgetsFor] offers the form, so a budget
  /// the form never showed can never be chosen here either.
  ///
  /// Also refuses when [amount] is more than that budget's remaining amount,
  /// recomputed from [effectiveBudgetsFor] inside this same write transaction
  /// (decision 2026-10-11): the app never writes a record it already knows
  /// is invalid, so an over-budget expense is never created here. Spec 6.4's
  /// "flagged and excluded" rule covers one received from the other
  /// partner instead (that phone's own writer had no say in it).
  Future<WriteResult> proposeExpense({
    required int amount,
    required String budgetId,
    String? receiptHash,
  }) => _propose(
    type: 'expense',
    refersTo: budgetId,
    budgetId: budgetId,
    amount: amount,
    bodyOf: (_, _, _) => {'amount': amount, 'receiptHash': receiptHash},
  );

  /// Proposes `withdraw_request` (spec section 5). [kind] is `"capital"` or
  /// `"profit"`. A capital withdrawal is investor only — the manager put in
  /// no capital, so there is nothing for them to withdraw (decision
  /// 2026-10-10). A profit withdrawal stays open to either partner.
  Future<WriteResult> proposeWithdrawal({
    required int amount,
    required String kind,
  }) => _propose(
    type: 'withdraw_request',
    kind: kind,
    bodyOf: (_, _, _) => {'amount': amount, 'kind': kind},
  );

  /// Proposes `budget_proposal`: a spending limit for [grantee] (spec
  /// section 5). Either partner may propose a budget for either partner —
  /// the grantee rule only limits who may later *spend* it ([proposeExpense]).
  Future<WriteResult> proposeBudget({
    required int amount,
    required String grantee,
  }) => _propose(
    type: 'budget_proposal',
    bodyOf: (_, _, _) => {'grantee': grantee, 'amount': amount},
  );

  /// Proposes `ratio_proposal`: a new profit-share split, effective from
  /// [effectiveFrom] (`YYYY-MM-DD`, spec section 5). Either partner.
  Future<WriteResult> proposeRatio({
    required int investorPercent,
    required int managerPercent,
    required String effectiveFrom,
  }) => _propose(
    type: 'ratio_proposal',
    bodyOf: (_, _, _) => {
      'ratio': {'investor': investorPercent, 'manager': managerPercent},
      'effectiveFrom': effectiveFrom,
    },
  );

  /// Proposes a `reversal` of [targetId] (spec section 5). Either partner.
  /// Refuses, without writing, when [targetId] is not held on this phone, or
  /// is not one of the types spec section 5 allows to be reversed — the app
  /// never writes a record it already knows is invalid.
  Future<WriteResult> proposeReversal({required String targetId}) => _propose(
    type: 'reversal',
    refersTo: targetId,
    reversalTarget: targetId,
    bodyOf: (_, _, _) => const {},
  );

  /// Proposes a `settlement` closing the open period at this phone's current
  /// chain vector (spec section 6.7; plan.md: "cut from the phone's current
  /// vector"). Manager only. Refuses with [WriteRefusal.emptyCut] when,
  /// beyond the last effective settlement's cut, the vector covers nothing
  /// but settlement bookkeeping (spec 6.7, cut rule 5; [coversNewBusiness]) —
  /// nothing has really happened for either partner since then.
  Future<WriteResult> proposeSettlement() => _propose(
    type: 'settlement',
    bodyOf: (_, validator, _) => {'cut': _openCut(validator)},
  );

  /// The open period's closing cut: each partner's highest seq currently
  /// held on this phone. This is always the last entry `periodShares` returns
  /// (the open period uses the whole ledger).
  Map<String, int> _openCut(Validator validator) => periodShares(
    validator.usableRecords,
    partnershipKeys: validator.partnershipKeys!,
  ).last.closingCut;

  /// Shared gate and write transaction for every creation form above (spec
  /// 7.4), mirroring [answer]'s structure: refuse, without writing, when this
  /// install is not known to be synced or caught up, or when the partnership
  /// is not active yet. [proposalRefusal] (`qirad_core`) then decides the
  /// type's own rule (its author's role, a budget's grantee and remaining
  /// amount, a reversal's target, an empty settlement cut) before anything
  /// is built. [bodyOf] sees the partnership's roles, read from the same
  /// accepted create. [kind], [budgetId], [amount] and [reversalTarget] are
  /// only the extra inputs [proposalRefusal] needs for some types — see its
  /// doc comment.
  Future<WriteResult> _propose({
    required String type,
    String? refersTo,
    required Map<String, dynamic> Function(
      List<Record> ledger,
      Validator validator,
      Parties parties,
    )
    bodyOf,
    String? kind,
    String? budgetId,
    int? amount,
    String? reversalTarget,
  }) async {
    // The gate reads the relay vector from the latest sync (spec 7.4, rule 2).
    final relayVector = await _store.relayVectorFor(partnership);
    if (relayVector == null) {
      return const WriteResult.refused(WriteRefusal.notSynced);
    }

    WriteRefusal? refusal;
    int? budgetLeft;
    final text = await _store.appendWith(partnership, (texts) async {
      final ledger = [
        for (final text in texts)
          Record.fromJson(jsonDecode(text) as Map<String, dynamic>),
      ];

      final localTop = ledger
          .where((r) => r.author == _me)
          .fold<int>(0, (top, r) => r.seq > top ? r.seq : top);
      if (!_store.isCaughtUpWithRelay(
        relayVector: relayVector,
        me: _me,
        localTop: localTop,
      )) {
        refusal = WriteRefusal.chainBehindRelay;
        return null;
      }

      final validator = _store.validatorFor(partnership);
      final keys = validator.partnershipKeys ?? const <String>{};
      final decisions = decideApprovals(
        validator.usableRecords,
        partnershipKeys: keys,
      );

      // Spec section 5: until the create is active, the only record anyone
      // may write is the manager's own answer to it (handled in [answer]).
      // Every creation form in this class comes after that bootstrap.
      if (partnershipStatus(decisions) != DecisionStatus.active) {
        refusal = WriteRefusal.partnershipNotActive;
        return null;
      }
      // Active means a well-formed create was accepted, so the roles exist.
      final parties = proposedParties(validator.usableRecords)!;

      final result = proposalRefusal(
        type: type,
        author: _me,
        parties: parties,
        ledger: ledger,
        validator: validator,
        kind: kind,
        budgetId: budgetId,
        amount: amount,
        reversalTarget: reversalTarget,
      );
      if (result != null) {
        refusal = _fromProposal(result.reason);
        budgetLeft = result.budgetLeft;
        return null;
      }

      // The builder reads my chain from [ledger], so the seq and prevHash
      // come from the saved records, never from the screen.
      final unsigned = buildRecord(
        ledger: ledger,
        author: _me,
        partnership: partnership,
        id: _newId(),
        type: type,
        body: bodyOf(ledger, validator, parties),
        time: _timeText(_now()),
        refersTo: refersTo,
      );

      // Every check has passed: this write will really happen. A test can
      // hold this open; a real run passes straight through.
      await _beforeSign();

      final signed = await signRecord(unsigned, _keys);
      return canonicalJson(signed.toJson());
    });

    if (text == null) {
      return WriteResult.refused(refusal!, budgetLeft: budgetLeft);
    }
    return WriteResult.written(
      Record.fromJson(jsonDecode(text) as Map<String, dynamic>),
    );
  }

  /// The display time in whole seconds, UTC, as the spec example shows (spec 3).
  static String _timeText(DateTime moment) =>
      '${moment.toUtc().toIso8601String().split('.').first}Z';
}
