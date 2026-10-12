import 'dart:math';

import 'package:qirad_core/qirad_core.dart';

import 'device.dart';
import 'sampling.dart';
import 'workload_config.dart';
import 'workload_run.dart';

/// Runs one seeded simulation of [config] through the real core rules and
/// returns both devices' final ledgers, in [WorkloadRun].
///
/// The same `(config, seed)` pair always produces the same run: every random
/// choice comes from one `Random(seed)`, and nothing here reads the system
/// clock (hard rule 3 — `time` fields are built from the simulated hour, not
/// `DateTime.now()`).
Future<WorkloadRun> generateWorkload(WorkloadConfig config, int seed) async {
  final engine = _Engine(config, seed);
  await engine.run();
  return WorkloadRun(
    config: config,
    seed: seed,
    partnershipId: engine.partnershipId,
    investor: engine.investor,
    manager: engine.manager,
    events: engine.events,
    refusals: engine.refusals,
    onlineFractionInvestor: _onlineFraction(engine.onlineInvestor),
    onlineFractionManager: _onlineFraction(engine.onlineManager),
  );
}

double _onlineFraction(List<bool> online) {
  if (online.isEmpty) return 0;
  return online.where((h) => h).length / online.length;
}

/// A record queued for delivery to the other device at a simulated hour —
/// how the generator models a relay sync, instead of delivering everything
/// the instant it is signed.
class _Delivery {
  _Delivery(this.hour, this.text);

  final int hour;
  final String text;
}

class _ScheduledReversal {
  _ScheduledReversal({required this.dueHour, required this.targetId});

  final int dueHour;
  final String targetId;
}

/// One item an [InboxItem] turned into, tracked across hours so the
/// "shown" consent summary is captured once, when the item first appears —
/// exactly like a partner opening the approval screen — and not refreshed
/// again until an answer attempt is actually refused (spec 6.7's staleness
/// check only means something if "shown" and "now" can really drift apart).
class _PendingAnswer {
  _PendingAnswer({
    required this.targetId,
    required this.targetType,
    required this.kind,
    required this.order,
    required this.canApprove,
    required this.blockedReason,
    required this.answerAtHour,
  });

  final String targetId;
  final String targetType;
  final InboxKind kind;

  /// The inbox's own order (author, then seq), so items are answered in a
  /// fixed, reproducible order each tick.
  final int order;

  bool canApprove;
  String? blockedReason;
  int answerAtHour;

  SettlementConsent? shownSettlement;
  WithdrawalConsent? shownWithdrawal;
  ReversalConsent? shownReversal;
  BudgetConsent? shownBudget;
  RatioConsent? shownRatio;
}

/// The simulation itself. Kept out of [generateWorkload] only so its many
/// pieces of running state (queues, schedules, pending answers) are fields
/// instead of a chain of parameters.
class _Engine {
  _Engine(this.config, this.seed) : rng = Random(seed);

  final WorkloadConfig config;
  final int seed;
  final Random rng;

  late String partnershipId;
  late Device investor;
  late Device manager;
  late String investorKey;
  late String managerKey;
  late Parties parties;
  late Set<String> partnershipKeys;

  late List<bool> onlineInvestor;
  late List<bool> onlineManager;

  /// True once the manager's approve of the `partnership_create` is written.
  /// Nothing but the create itself is effective before that (spec section
  /// 5), so sales, expenses and the rest wait for it.
  bool partnershipActive = false;

  /// Forces one inbox scan at hour 0, even though nothing is pending yet.
  bool dirtyInvestor = true;
  bool dirtyManager = true;

  int nextRatioDay = 0;
  int nextSettlementDay = 0;

  final List<WorkloadEvent> events = [];
  final List<RefusalEvent> refusals = [];
  final List<_Delivery> pendingToInvestor = [];
  final List<_Delivery> pendingToManager = [];
  final List<_ScheduledReversal> scheduledReversals = [];
  final Map<String, _PendingAnswer> pendingAnswersInvestor = {};
  final Map<String, _PendingAnswer> pendingAnswersManager = {};

  Future<void> run() async {
    final investorKeyPair = await generateEd25519KeyPair();
    final managerKeyPair = await generateEd25519KeyPair();
    investorKey = investorKeyPair.publicKeyBase64Url;
    managerKey = managerKeyPair.publicKeyBase64Url;
    partnershipKeys = {investorKey, managerKey};
    parties = Parties(investor: investorKey, manager: managerKey);
    partnershipId = _uuidV4();

    investor = Device(
      keyPair: investorKeyPair,
      validator: Validator(
        pinnedInvestorKey: investorKey,
        pinnedManagerKey: managerKey,
      ),
    );
    manager = Device(
      keyPair: managerKeyPair,
      validator: Validator(
        pinnedInvestorKey: investorKey,
        pinnedManagerKey: managerKey,
      ),
    );

    final totalHours = config.days * 24;
    onlineInvestor = _buildOnlineSchedule(totalHours);
    onlineManager = _buildOnlineSchedule(totalHours);

    nextRatioDay = config.ratioChangeIntervalDays;
    nextSettlementDay = config.settlementIntervalDays;

    for (var day = 0; day < config.days; day++) {
      final dayStartHour = day * 24;

      if (day == 0) {
        // The partnership is bootstrapped, and the investor logs the agreed
        // starting capital right away (the user's "the month starts with an
        // investment"). It is stored immediately, and becomes effective
        // retroactively once the manager's approve arrives (spec section 5).
        await _createPartnership(dayStartHour);
        final amount = _paisa(logUniformInt(rng, config.initialInvestment));
        await _buildSignStore(
          device: investor,
          type: 'invest',
          body: {'amount': amount},
          hour: dayStartHour,
        );
      } else {
        await _dailyTasks(day, dayStartHour);
      }

      for (var h = 0; h < 24; h++) {
        final hour = dayStartHour + h;
        await _processDueDeliveries(hour);
        await _hourlyTasks(hour);
        await _answerPending(hour);
      }
    }
  }

  // ---- bootstrap -----------------------------------------------------

  Future<void> _createPartnership(int hour) async {
    await _buildSignStore(
      device: investor,
      type: 'partnership_create',
      body: {
        'investor': investorKey,
        'manager': managerKey,
        'ratio': {'investor': 60, 'manager': 40},
        'currency': 'PKR',
      },
      hour: hour,
      id: partnershipId,
    );
  }

  // ---- once-a-day business events -------------------------------------

  Future<void> _dailyTasks(int day, int hour) async {
    if (!partnershipActive) return;

    if (bernoulli(rng, config.additionalInvestmentDailyChance)) {
      final amount = _paisa(
        logUniformInt(rng, config.additionalInvestmentAmount),
      );
      await _buildSignStore(
        device: investor,
        type: 'invest',
        body: {'amount': amount},
        hour: hour,
      );
    }

    if (bernoulli(rng, config.capitalWithdrawalDailyChance)) {
      final cash = _cashBalance(investor);
      if (cash > 0) {
        final fraction = uniformDouble(rng, config.capitalWithdrawalFraction);
        final amount = (cash * fraction).round();
        if (amount > 0) {
          await _buildSignStore(
            device: investor,
            type: 'withdraw_request',
            body: {'amount': amount, 'kind': 'capital'},
            hour: hour,
          );
        }
      }
    }

    await _maybeRenewBudget(hour);
    await _maybeProposeRatio(day, hour);
    await _maybeProposeSettlement(day, hour);
  }

  /// The manager proposes a new budget once the current one (if any) has
  /// less than [WorkloadConfig.budgetRenewalThreshold] of its amount left —
  /// a business condition, not a timer, so a refusal here (if any) reflects
  /// the system, not the simulation's clock.
  ///
  /// A real manager also would not send a second ask while the first is
  /// still unanswered, so this first checks whether she already has a
  /// `budget_proposal` of her own still pending (no counted response yet) —
  /// otherwise the daily check would re-propose every single day the budget
  /// stays low, independent of whether the investor has had a chance to
  /// answer the one already sent.
  Future<void> _maybeRenewBudget(int hour) async {
    final hasPendingProposal = decideApprovals(
      manager.validator.usableRecords,
      partnershipKeys: partnershipKeys,
    ).any(
      (d) =>
          d.status == DecisionStatus.pending &&
          d.target.type == 'budget_proposal' &&
          d.target.author == managerKey,
    );
    if (hasPendingProposal) return;

    final remaining = effectiveBudgetsFor(
      manager.validator.usableRecords,
      partnershipKeys: partnershipKeys,
      grantee: managerKey,
    );
    final byId = {for (final r in manager.validator.ledger.records) r.id: r};

    var totalLeft = 0;
    var totalOriginal = 0;
    for (final entry in remaining.entries) {
      totalLeft += entry.value;
      totalOriginal += (byId[entry.key]?.body['amount'] as int?) ?? 0;
    }

    final low =
        remaining.isEmpty ||
        totalOriginal == 0 ||
        (totalLeft / totalOriginal) < config.budgetRenewalThreshold;
    if (!low) return;

    final typicalExpense = _paisa(
      _geometricMean(config.expenseAmount).round(),
    );
    final amount =
        (config.budgetCoverageDays * config.expensesPerDay * typicalExpense)
            .round();
    await _proposeChecked(
      device: manager,
      type: 'budget_proposal',
      body: {'grantee': managerKey, 'amount': amount},
      hour: hour,
    );
  }

  Future<void> _maybeProposeRatio(int day, int hour) async {
    if (day < nextRatioDay) return;
    nextRatioDay = day + config.ratioChangeIntervalDays + _jitter(
      config.ratioChangeIntervalDays,
    );

    final investorShare = 30 + rng.nextInt(51); // 30..80
    final leadDays = uniformInt(rng, config.ratioEffectiveFromLeadDays);
    await _proposeChecked(
      device: investor,
      type: 'ratio_proposal',
      body: {
        'ratio': {'investor': investorShare, 'manager': 100 - investorShare},
        'effectiveFrom': _isoDate(day + leadDays),
      },
      hour: hour,
    );
  }

  Future<void> _maybeProposeSettlement(int day, int hour) async {
    if (day < nextSettlementDay) return;
    nextSettlementDay = day + config.settlementIntervalDays + _jitter(
      config.settlementIntervalDays,
    );

    final investorSeq = _highestSeqFor(manager.validator, investorKey);
    final managerSeq = manager.validator.ledger.records
        .where((r) => r.author == managerKey)
        .length;
    await _proposeChecked(
      device: manager,
      type: 'settlement',
      body: {
        'cut': {investorKey: investorSeq, managerKey: managerSeq},
      },
      hour: hour,
    );
  }

  /// A small random offset around an interval, so settlements and ratio
  /// changes do not all land on exactly the same day of the month.
  int _jitter(int intervalDays) {
    final spread = (intervalDays * 0.1).round().clamp(1, 1 << 30);
    return rng.nextInt(spread * 2 + 1) - spread;
  }

  // ---- once-an-hour business events ------------------------------------

  Future<void> _hourlyTasks(int hour) async {
    if (!partnershipActive) return;

    if (bernoulli(rng, hourlyChanceFromDailyRate(config.salesPerDay))) {
      final amount = _paisa(logUniformInt(rng, config.saleAmount));
      final sale = await _buildSignStore(
        device: manager,
        type: 'sale',
        body: {'amount': amount},
        hour: hour,
      );
      if (bernoulli(rng, config.saleMistakeRate)) {
        _scheduleReversal(target: sale, hour: hour);
      }
    }

    if (bernoulli(rng, hourlyChanceFromDailyRate(config.expensesPerDay))) {
      final budgets = effectiveBudgetsFor(
        manager.validator.usableRecords,
        partnershipKeys: partnershipKeys,
        grantee: managerKey,
      );
      if (budgets.isNotEmpty) {
        final budgetId = budgets.keys.elementAt(rng.nextInt(budgets.length));
        final amount = _paisa(logUniformInt(rng, config.expenseAmount));
        // Not clamped to what is left: an amount that does not fit is a real
        // attempt core refuses (overBudget), not a staged one.
        final expense = await _proposeChecked(
          device: manager,
          type: 'expense',
          body: {'amount': amount},
          hour: hour,
          refersTo: budgetId,
          budgetId: budgetId,
          amount: amount,
        );
        if (expense != null && bernoulli(rng, config.expenseMistakeRate)) {
          _scheduleReversal(target: expense, hour: hour);
        }
      }
    }

    await _processScheduledReversals(hour);
  }

  void _scheduleReversal({required Record target, required int hour}) {
    final delay = uniformInt(rng, config.reversalDelayHours);
    scheduledReversals.add(
      _ScheduledReversal(dueHour: hour + delay, targetId: target.id),
    );
  }

  Future<void> _processScheduledReversals(int hour) async {
    final due = scheduledReversals.where((r) => r.dueHour <= hour).toList();
    if (due.isEmpty) return;
    scheduledReversals.removeWhere((r) => r.dueHour <= hour);
    for (final reversal in due) {
      await _proposeChecked(
        device: manager,
        type: 'reversal',
        body: const {},
        hour: hour,
        refersTo: reversal.targetId,
        reversalTarget: reversal.targetId,
      );
    }
  }

  /// After a settlement becomes effective, each partner sometimes asks for a
  /// share of their now-settled profit.
  Future<void> _maybeRequestProfitWithdrawals(int hour) async {
    for (final device in [investor, manager]) {
      if (!bernoulli(rng, config.profitWithdrawalChance)) continue;

      final isInvestor = device == investor;
      final periods = periodShares(
        device.validator.usableRecords,
        partnershipKeys: partnershipKeys,
      ).where((p) => !p.open);

      var settledShare = 0;
      for (final p in periods) {
        settledShare += isInvestor
            ? p.shares.investor + p.correction.investor
            : p.shares.manager + p.correction.manager;
      }
      final already =
          totalProfitWithdrawn(
            device.validator.usableRecords,
            partnershipKeys: partnershipKeys,
          )[device.key] ??
          0;
      final available = settledShare - already;
      if (available <= 0) continue;

      final fraction = uniformDouble(rng, config.profitWithdrawalFraction);
      final amount = (available * fraction).round();
      if (amount <= 0) continue;

      await _buildSignStore(
        device: device,
        type: 'withdraw_request',
        body: {'amount': amount, 'kind': 'profit'},
        hour: hour,
      );
    }
  }

  // ---- answering the inbox ---------------------------------------------

  Future<void> _answerPending(int hour) async {
    await _answerForDevice(investor, hour);
    await _answerForDevice(manager, hour);
  }

  Future<void> _answerForDevice(Device device, int hour) async {
    final isInvestor = device == investor;
    final dirty = isInvestor ? dirtyInvestor : dirtyManager;
    final pendingMap = _pendingByDevice(device);

    if (dirty) {
      final items = approvalsInbox(
        device.validator.usableRecords,
        partnershipKeys: partnershipKeys,
        myKey: device.key,
      );
      final seenIds = {for (final item in items) item.target.id};
      pendingMap.removeWhere((id, _) => !seenIds.contains(id));
      for (var i = 0; i < items.length; i++) {
        final item = items[i];
        final existing = pendingMap[item.target.id];
        if (existing == null) {
          pendingMap[item.target.id] = _makePendingAnswer(device, item, i, hour);
        } else {
          existing.canApprove = item.canApprove;
          existing.blockedReason = item.blockedReason;
        }
      }
      if (isInvestor) {
        dirtyInvestor = false;
      } else {
        dirtyManager = false;
      }
    }

    final ready = pendingMap.values.where((p) => p.answerAtHour <= hour).toList()
      ..sort((a, b) => a.order.compareTo(b.order));

    for (final pending in ready) {
      if (pending.kind == InboxKind.settlement && !pending.canApprove) {
        final reason = pending.blockedReason;
        // Some blocks are permanent (the screen's own text says "Reject
        // it"); others may clear once more records sync, so those are just
        // retried later instead of rejected on a guess.
        if (reason != null && reason.contains('Reject it')) {
          await _attemptAnswer(device, pending, hour, approve: false);
        }
        continue;
      }
      final approve = pending.kind == InboxKind.settlement
          ? !bernoulli(rng, config.settlementRejectChance)
          : true;
      await _attemptAnswer(device, pending, hour, approve: approve);
    }
  }

  _PendingAnswer _makePendingAnswer(
    Device device,
    InboxItem item,
    int order,
    int hour,
  ) {
    final pending = _PendingAnswer(
      targetId: item.target.id,
      targetType: item.target.type,
      kind: item.kind,
      order: order,
      canApprove: item.canApprove,
      blockedReason: item.blockedReason,
      answerAtHour: hour + uniformInt(rng, config.answerDelayHours),
    );
    _captureShown(device, item, pending, hour);
    return pending;
  }

  /// Captures the consent summary the partner would see right now, exactly
  /// once, so a later ledger change between now and the scheduled answer can
  /// make it stale — the scenario spec 6.7's staleness check exists for.
  void _captureShown(
    Device device,
    InboxItem item,
    _PendingAnswer pending,
    int hour,
  ) {
    if (item.kind == InboxKind.partnershipStart) {
      return; // answerConsent has no summary type for this one.
    }
    final candidate = buildRecord(
      ledger: device.validator.ledger.records,
      author: device.key,
      partnership: partnershipId,
      id: _uuidV4(),
      type: 'approve',
      body: const {},
      time: _isoTime(hour),
      refersTo: item.target.id,
    );
    switch (item.kind) {
      case InboxKind.settlement:
        pending.shownSettlement = settlementConsent(
          device.validator.usableRecords,
          partnershipKeys: partnershipKeys,
          proposal: item.target,
          answer: candidate,
        );
      case InboxKind.withdrawal:
        pending.shownWithdrawal = withdrawalConsent(
          device.validator.usableRecords,
          partnershipKeys: partnershipKeys,
          request: item.target,
          answer: candidate,
        );
      case InboxKind.reversal:
        pending.shownReversal = reversalConsent(
          device.validator.usableRecords,
          partnershipKeys: partnershipKeys,
          reversal: item.target,
          answer: candidate,
        );
      case InboxKind.budget:
        pending.shownBudget = budgetConsent(
          device.validator.usableRecords,
          partnershipKeys: partnershipKeys,
          proposal: item.target,
        );
      case InboxKind.ratio:
        pending.shownRatio = ratioConsent(
          device.validator.usableRecords,
          partnershipKeys: partnershipKeys,
          proposal: item.target,
        );
      case InboxKind.partnershipStart:
        break;
    }
  }

  Future<void> _attemptAnswer(
    Device device,
    _PendingAnswer pending,
    int hour, {
    required bool approve,
  }) async {
    final targetId = pending.targetId;

    final eligibility = answerEligibility(
      targetId: targetId,
      me: device.key,
      validator: device.validator,
    );
    if (eligibility != null) {
      refusals.add(
        RefusalEvent(
          hour: hour,
          stage: 'answerEligibility',
          type: pending.targetType,
          actor: _actorOf(device),
          reason: eligibility.name,
        ),
      );
      if (eligibility == AnswerEligibilityRefusal.alreadyAnswered ||
          eligibility == AnswerEligibilityRefusal.alreadyDecided) {
        _pendingByDevice(device).remove(targetId);
      }
      return;
    }

    final candidate = buildRecord(
      ledger: device.validator.ledger.records,
      author: device.key,
      partnership: partnershipId,
      id: _uuidV4(),
      type: approve ? 'approve' : 'reject',
      body: const {},
      time: _isoTime(hour),
      refersTo: targetId,
    );

    final result = answerConsent(
      targetId: targetId,
      approve: approve,
      candidate: candidate,
      validator: device.validator,
      shownSettlement: pending.shownSettlement,
      shownWithdrawal: pending.shownWithdrawal,
      shownReversal: pending.shownReversal,
      shownBudget: pending.shownBudget,
      shownRatio: pending.shownRatio,
    );

    if (result != null) {
      refusals.add(
        RefusalEvent(
          hour: hour,
          stage: 'answerConsent',
          type: pending.targetType,
          actor: _actorOf(device),
          reason: result.reason.name,
        ),
      );
      // The partner looks again, like reopening the approval screen, and
      // tries again a little later with the numbers as they stand now.
      pending.shownSettlement = result.latestSettlement ?? pending.shownSettlement;
      pending.shownWithdrawal = result.latestWithdrawal ?? pending.shownWithdrawal;
      pending.shownReversal = result.latestReversal ?? pending.shownReversal;
      pending.shownBudget = result.latestBudget ?? pending.shownBudget;
      pending.shownRatio = result.latestRatio ?? pending.shownRatio;
      pending.answerAtHour = hour + 1 + rng.nextInt(4);
      return;
    }

    final signed = await signRecord(candidate, device.keyPair);
    final text = canonicalJson(signed.toJson());
    final outcome = await device.validator.receiveText(text);
    assert(outcome == ReceiveOutcome.accepted);
    events.add(
      WorkloadEvent(
        hour: hour,
        recordId: signed.id,
        type: signed.type,
        author: _actorOf(device),
      ),
    );
    _scheduleDelivery(from: device, text: text, authorHour: hour);
    _markDirty(_otherDevice(device));
    _pendingByDevice(device).remove(targetId);

    if (!approve) return;
    if (pending.kind == InboxKind.partnershipStart) {
      partnershipActive = true;
    } else if (pending.kind == InboxKind.settlement) {
      await _maybeRequestProfitWithdrawals(hour);
    }
  }

  // ---- writing and delivering records ----------------------------------

  Future<Record> _buildSignStore({
    required Device device,
    required String type,
    required Map<String, dynamic> body,
    required int hour,
    String? refersTo,
    String? id,
  }) async {
    final unsigned = buildRecord(
      ledger: device.validator.ledger.records,
      author: device.key,
      partnership: partnershipId,
      id: id ?? _uuidV4(),
      type: type,
      body: body,
      time: _isoTime(hour),
      refersTo: refersTo,
    );
    final signed = await signRecord(unsigned, device.keyPair);
    final text = canonicalJson(signed.toJson());
    final outcome = await device.validator.receiveText(text);
    assert(
      outcome == ReceiveOutcome.accepted,
      'self-authored record was not accepted: $outcome',
    );
    events.add(
      WorkloadEvent(
        hour: hour,
        recordId: signed.id,
        type: type,
        author: _actorOf(device),
      ),
    );
    _scheduleDelivery(from: device, text: text, authorHour: hour);
    _markDirty(_otherDevice(device));
    return signed;
  }

  /// Like [_buildSignStore], but only once [proposalRefusal] (the same check
  /// `RecordWriter.propose*` runs) has agreed the write is allowed. Returns
  /// `null`, and logs why, when it would be refused.
  Future<Record?> _proposeChecked({
    required Device device,
    required String type,
    required Map<String, dynamic> body,
    required int hour,
    String? refersTo,
    String? kind,
    String? budgetId,
    int? amount,
    String? reversalTarget,
  }) async {
    final refusal = proposalRefusal(
      type: type,
      author: device.key,
      parties: parties,
      ledger: device.validator.ledger.records.toList(),
      validator: device.validator,
      kind: kind,
      budgetId: budgetId,
      amount: amount,
      reversalTarget: reversalTarget,
    );
    if (refusal != null) {
      refusals.add(
        RefusalEvent(
          hour: hour,
          stage: 'proposal',
          type: type,
          actor: _actorOf(device),
          reason: refusal.reason.name,
        ),
      );
      return null;
    }
    return _buildSignStore(
      device: device,
      type: type,
      body: body,
      hour: hour,
      refersTo: refersTo,
    );
  }

  // ---- network and offline model ---------------------------------------

  /// Builds one device's online/offline hours for the whole run.
  ///
  /// Day 0 is always online: the partners set the partnership up in person
  /// (the QR key exchange), so there is nothing to be offline *from* yet.
  /// After that, two independent things can mark hours offline, and neither
  /// is allowed to mark an hour that is already offline — periods never
  /// overlap or stack, so "offline" always means a fresh gap, not several
  /// gaps piled on top of each other:
  ///   - a short daily period (both configs): a work gap or overnight.
  ///   - a long weekly episode (`stress` only): about once a week, 1-3 days
  ///     of a genuinely dropped connection, long enough to force real
  ///     divergence before the next sync.
  List<bool> _buildOnlineSchedule(int totalHours) {
    final online = List<bool>.filled(totalHours, true);
    const firstOnlineHours = 24;
    if (totalHours <= firstOnlineHours) return online;

    bool fullyOnline(int start, int duration) {
      final end = min(start + duration, totalHours);
      for (var h = start; h < end; h++) {
        if (!online[h]) return false;
      }
      return true;
    }

    void markOffline(int start, int duration) {
      final end = min(start + duration, totalHours);
      for (var h = start; h < end; h++) {
        online[h] = false;
      }
    }

    if (config.longOfflineEpisodeChancePerWeek > 0) {
      var weekStart = firstOnlineHours;
      while (weekStart < totalHours) {
        final weekEnd = min(weekStart + 24 * 7, totalHours);
        if (bernoulli(rng, config.longOfflineEpisodeChancePerWeek)) {
          final duration = uniformInt(rng, config.longOfflineEpisodeDays) * 24;
          final latestStart = weekEnd - duration;
          if (latestStart > weekStart) {
            final start = weekStart + rng.nextInt(latestStart - weekStart);
            if (fullyOnline(start, duration)) markOffline(start, duration);
          }
        }
        weekStart = weekEnd;
      }
    }

    for (var dayStart = firstOnlineHours;
        dayStart < totalHours;
        dayStart += 24) {
      final dayEnd = min(dayStart + 24, totalHours);
      final count = uniformInt(rng, config.shortOfflinePeriodsPerDay);
      for (var i = 0; i < count; i++) {
        final duration = uniformInt(rng, config.shortOfflinePeriodHours);
        final latestStart = dayEnd - duration;
        if (latestStart <= dayStart) continue;
        final start = dayStart + rng.nextInt(latestStart - dayStart);
        if (fullyOnline(start, duration)) markOffline(start, duration);
      }
    }

    return online;
  }

  int _nextOnlineHour(List<bool> online, int from) {
    var h = from < 0 ? 0 : from;
    while (h < online.length && !online[h]) {
      h++;
    }
    return h >= online.length ? online.length - 1 : h;
  }

  void _scheduleDelivery({
    required Device from,
    required String text,
    required int authorHour,
  }) {
    final fromInvestor = from == investor;
    final senderOnline = fromInvestor ? onlineInvestor : onlineManager;
    final recipientOnline = fromInvestor ? onlineManager : onlineInvestor;
    final queue = fromInvestor ? pendingToManager : pendingToInvestor;

    final pushHour = _nextOnlineHour(senderOnline, authorHour);
    final relayHours = (uniformInt(rng, config.relayDelaySeconds) / 3600)
        .ceil();
    var arriveHour = pushHour + relayHours;
    if (bernoulli(rng, config.reorderChance)) {
      // Held back on purpose, so a later record from the same author can
      // overtake it and the recipient must buffer a real chain gap.
      arriveHour += 2 + rng.nextInt(23);
    }
    final deliverHour = _nextOnlineHour(recipientOnline, arriveHour);

    queue.add(_Delivery(deliverHour, text));
    if (bernoulli(rng, config.duplicateRate)) {
      // A retried sync resending a record the relay already has.
      queue.add(_Delivery(deliverHour, text));
    }
  }

  Future<void> _processDueDeliveries(int hour) async {
    await _deliver(pendingToInvestor, investor, hour);
    await _deliver(pendingToManager, manager, hour);
  }

  Future<void> _deliver(
    List<_Delivery> queue,
    Device recipient,
    int hour,
  ) async {
    final due = queue.where((d) => d.hour <= hour).toList();
    if (due.isEmpty) return;
    queue.removeWhere((d) => d.hour <= hour);
    for (final delivery in due) {
      await recipient.validator.receiveText(delivery.text);
    }
    _markDirty(recipient);
  }

  // ---- small helpers -----------------------------------------------------

  Map<String, _PendingAnswer> _pendingByDevice(Device device) =>
      device == investor ? pendingAnswersInvestor : pendingAnswersManager;

  Device _otherDevice(Device device) => device == investor ? manager : investor;

  Actor _actorOf(Device device) =>
      device == investor ? Actor.investor : Actor.manager;

  void _markDirty(Device device) {
    if (device == investor) {
      dirtyInvestor = true;
    } else {
      dirtyManager = true;
    }
  }

  int _cashBalance(Device device) {
    final effectiveness = computeEffective(
      device.validator.usableRecords,
      partnershipKeys: partnershipKeys,
    );
    return computeMoney(
      device.validator.usableRecords,
      effectiveness: effectiveness,
    ).cashBalance;
  }

  int _highestSeqFor(Validator validator, String author) {
    var highest = 0;
    for (final r in validator.usableRecords) {
      if (r.author == author && r.seq > highest) highest = r.seq;
    }
    return highest;
  }

  String _isoTime(int hour) {
    final dt = DateTime.utc(2026, 1, 1).add(Duration(hours: hour));
    return '${_pad4(dt.year)}-${_pad2(dt.month)}-${_pad2(dt.day)}'
        'T${_pad2(dt.hour)}:${_pad2(dt.minute)}:${_pad2(dt.second)}Z';
  }

  String _isoDate(int day) {
    final dt = DateTime.utc(2026, 1, 1).add(Duration(days: day));
    return '${_pad4(dt.year)}-${_pad2(dt.month)}-${_pad2(dt.day)}';
  }

  String _pad2(int v) => v.toString().padLeft(2, '0');
  String _pad4(int v) => v.toString().padLeft(4, '0');

  int _paisa(int rupees) => rupees * paisaPerRupee;

  double _geometricMean(IntRange range) => sqrt(range.min * range.max);

  /// A record id in the same shape core requires (version 4, variant
  /// 8/9/a/b — see `validator.dart`'s `_uuidV4`), drawn from this run's own
  /// seeded [rng] instead of a package-level random source, so the whole
  /// run — ids included — is reproducible from `(config, seed)` alone.
  String _uuidV4() {
    const hex = '0123456789abcdef';
    final chars = List<String>.generate(32, (_) => hex[rng.nextInt(16)]);
    chars[12] = '4';
    chars[16] = hex[8 + rng.nextInt(4)]; // 8, 9, a or b
    final s = chars.join();
    return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
        '-${s.substring(16, 20)}-${s.substring(20, 32)}';
  }
}
