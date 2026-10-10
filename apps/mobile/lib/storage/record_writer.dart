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

  /// Proposes `invest`: adds capital (spec section 5). Investor only.
  Future<WriteResult> proposeInvest({required int amount}) => _propose(
    type: 'invest',
    bodyOf: (_, _, _) => {'amount': amount},
    refusalOf: (_, _, parties) =>
        _me == parties.investor ? null : WriteRefusal.wrongRole,
  );

  /// Proposes `sale`: adds income (spec section 5). Manager only.
  Future<WriteResult> proposeSale({required int amount}) => _propose(
    type: 'sale',
    bodyOf: (_, _, _) => {'amount': amount},
    refusalOf: (_, _, parties) =>
        _me == parties.manager ? null : WriteRefusal.wrongRole,
  );

  /// Proposes `expense`: removes money, drawn from [budgetId] (spec section
  /// 5, 6.4). Manager only, and only from a budget this key is the grantee
  /// of — the same list [effectiveBudgetsFor] offers the form, so a budget
  /// the form never showed can never be chosen here either.
  Future<WriteResult> proposeExpense({
    required int amount,
    required String budgetId,
    String? receiptHash,
  }) => _propose(
    type: 'expense',
    refersTo: budgetId,
    bodyOf: (_, _, _) => {'amount': amount, 'receiptHash': receiptHash},
    refusalOf: (_, validator, parties) {
      if (_me != parties.manager) return WriteRefusal.wrongRole;
      final budgets = effectiveBudgetsFor(
        validator.usableRecords,
        partnershipKeys: validator.partnershipKeys!,
        grantee: _me,
      );
      return budgets.containsKey(budgetId)
          ? null
          : WriteRefusal.noEffectiveBudget;
    },
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
    bodyOf: (_, _, _) => {'amount': amount, 'kind': kind},
    refusalOf: (_, _, parties) {
      if (kind == 'capital' && _me != parties.investor) {
        return WriteRefusal.wrongRole;
      }
      return null;
    },
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
    bodyOf: (_, _, _) => const {},
    refusalOf: (ledger, _, _) {
      const reversible = {'invest', 'sale', 'expense', 'withdraw_request'};
      final target = ledger.where((r) => r.id == targetId);
      if (target.isEmpty || !reversible.contains(target.single.type)) {
        return WriteRefusal.notReversible;
      }
      return null;
    },
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
    refusalOf: (_, validator, parties) {
      if (_me != parties.manager) return WriteRefusal.wrongRole;
      final shares = periodShares(
        validator.usableRecords,
        partnershipKeys: validator.partnershipKeys!,
      );
      final candidate = _openCut(validator);
      final previous = shares.length >= 2
          ? shares[shares.length - 2].closingCut
          : {parties.investor: 0, parties.manager: 0};
      final coversNew = coversNewBusiness(
        previous,
        candidate,
        validator.usableRecords,
      );
      return coversNew ? null : WriteRefusal.emptyCut;
    },
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
  /// is not active yet. [refusalOf] runs after that and before anything is
  /// built, so a type's own rule (its author's role, a budget's grantee, an
  /// empty settlement cut) can refuse too. [bodyOf] and [refusalOf] both see
  /// the partnership's roles, read from the same accepted create.
  Future<WriteResult> _propose({
    required String type,
    String? refersTo,
    required Map<String, dynamic> Function(
      List<Record> ledger,
      Validator validator,
      Parties parties,
    )
    bodyOf,
    WriteRefusal? Function(
      List<Record> ledger,
      Validator validator,
      Parties parties,
    )?
    refusalOf,
  }) async {
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

      refusal = refusalOf?.call(ledger, validator, parties);
      if (refusal != null) return null;

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
      return WriteResult.refused(refusal!);
    }
    return WriteResult.written(
      Record.fromJson(jsonDecode(text) as Map<String, dynamic>),
    );
  }

  /// The display time in whole seconds, UTC, as the spec example shows (spec 3).
  static String _timeText(DateTime moment) =>
      '${moment.toUtc().toIso8601String().split('.').first}Z';
}
