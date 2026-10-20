// RQ4 — Security. Does the system detect every attack, and does no attack
// change the honest partner's numbers?
//
// Method (see docs/evaluation/README.md's "Research questions" for the full
// write-up): take an honest generated run, inject ONE crafted attack record
// into a receiving device's live validator, and check two things:
//
//   - detected: the validator's actual outcome matches the expected one
//     (for the over-budget attack, this also means `ExpenseStatus.overBudget`,
//     since the validator itself still accepts that record — overBudget is a
//     business fact, not a validator rejection).
//   - noImpact: the receiving device's dashboard numbers are identical
//     before and after the attack record is fed in (only evidence/flags may
//     differ).
//
// Nine attack types from the spec, as ten checks here (the spec's item 8,
// "non-canonical bytes ... ; malformed schema ...", covers two different
// expected outcomes, so it is split into two attack types for a clean one
// outcome per row):
//
//   1. signatureTamper   — change a field of a real signed record, keep the
//      old sig. Expected: rejectedSignature.
//   2. outsideKey        — a key that is not a partner signs a record.
//      Expected: rejectedMembership.
//   3. wrongRole         — a real partner key signs a type it may not author
//      (cycles manager-signs-invest / investor-signs-sale / manager-requests-
//      capital-withdrawal across seeds). Expected: rejectedMembership.
//   4. forgedCreate      — a valid signature but a different investor key,
//      sent to a joining device with pinned keys. Expected: rejectedMembership,
//      and the real create is still accepted afterwards.
//   5. chainTamper       — the real author signs its next record with a wrong
//      prevHash. Expected: chainInvalid.
//   6. equivocation       — the real author signs two different records with
//      the same seq. Expected: equivocating on the receiving device, AND (via
//      an in-memory relay) the other partner also flags the same author.
//   7. idConflict        — a new record reuses an existing record's id with
//      different content. Expected: idConflict.
//   8. nonCanonical       — valid JSON, wrong bytes (extra space, duplicate
//      key, unsorted keys). Expected: rejectedNotCanonical.
//   9. malformedSchema    — a required field missing, or the wrong type.
//      Expected: rejectedSchema.
//  10. overBudgetExpense — a valid, correctly-chained expense that breaks a
//      real budget. Expected: accepted by the validator, but excluded from
//      every number (ExpenseStatus.overBudget).
//
// Equivocation does not get a single noImpact check. Quarantining an
// equivocating author's chain from the flagged seq onward is deliberate core
// behaviour (see validator.dart's usableRecords), and it provably has
// collateral effects: it can also exclude later records by that SAME author
// that the quarantine was never trying to catch, including their OWN
// approvals and settlement-cut records. So equivocation is measured with
// three precise checks instead, and two extra, deliberately targeted attack
// variants are added to probe exactly where that collateral damage lands:
//
//  11. equivocationAtBudgetApprove — the investor equivocates at the exact
//      seq of their own `approve` of one of the manager's budget_proposals.
//  12. equivocationAtSettlementCut — the investor equivocates at the exact
//      seq of one of their own records that sits inside an already-effective
//      settlement's cut.
//
// All three equivocation-family attacks report:
//   - forgedExcluded    — no record at all (forged or original) survives at
//     the targeted (author, seq) position after the attack.
//   - honestUnaffected  — every one of the OTHER (non-equivocating) partner's
//     own records keeps the same effective/expense status it had before.
//   - settledUnchanged  — every settlement that was effective before the
//     attack is still effective, with the same cut, after it.
// See docs/decisions.md and docs/evaluation/README.md's "Findings" section
// for what this showed and why it is not being changed in qirad_core.
//
// Any attack that is not detected, or that does have impact, is printed as a
// FINDING line and still written to the CSV — never hidden.
//
// Output: docs/evaluation/rq4_security.csv (one row per successful attempt)
// and docs/evaluation/rq4_security_summary.csv (detected/total and
// noImpact/total per attack type and config).
//
// Usage: dart run tool/rq4_security.dart [seedsPerAttack]
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:evaluation/evaluation.dart';
import 'package:qirad_core/qirad_core.dart';

// Most attacks need at most a handful of real records to attach to (a chain
// head, an active budget), but equivocationAtSettlementCut specifically
// needs a settlement that has already reached SettlementState.effective —
// which needs its 30-day proposal interval PLUS the investor's response to
// land inside the run, just like RQ1/RQ2's 90-day requirement (see that
// tool's comments). So this uses the same 90 days, even though most attack
// types here do not need it.
const _days = 90;

// How many seeds to scan looking for `seedsPerAttack` usable ones. Some
// attacks have a precondition an unlucky seed may not satisfy (mainly
// overBudgetExpense, which needs an active budget) — those seeds are
// skipped, not counted as a result either way.
const _seedPoolSize = 400;

Future<void> main(List<String> args) async {
  final seedsPerAttack = args.isNotEmpty ? int.parse(args[0]) : 50;

  final resultsFile = File('../../docs/evaluation/rq4_security.csv')
    ..writeAsStringSync(
      'config,seed,attackType,expectedOutcome,actualOutcome,detected,noImpact,'
      'forgedExcluded,honestUnaffected,settledUnchanged\n',
    );

  final tallies = <String, Map<AttackType, _Tally>>{};

  for (final configName in ['realistic', 'stress']) {
    tallies[configName] = {for (final a in AttackType.values) a: _Tally()};

    for (final attack in AttackType.values) {
      final tally = tallies[configName]![attack]!;
      var done = 0;

      for (var seed = 1; seed <= _seedPoolSize && done < seedsPerAttack; seed++) {
        final config = configName == 'stress'
            ? WorkloadConfig.stress(days: _days)
            : WorkloadConfig.realistic(days: _days);

        final outcome = await _runAttack(attack, config, seed);
        if (outcome == null) continue; // this seed's run has no precondition for this attack

        done++;
        tally.total++;
        if (outcome.detected) tally.detectedCount++;
        if (outcome.noImpact ?? false) tally.noImpactCount++;
        if (outcome.forgedExcluded != null) {
          tally.forgedExcludedTotal++;
          if (outcome.forgedExcluded!) tally.forgedExcludedCount++;
        }
        if (outcome.honestUnaffected != null) {
          tally.honestUnaffectedTotal++;
          if (outcome.honestUnaffected!) tally.honestUnaffectedCount++;
        }
        if (outcome.settledUnchanged != null) {
          tally.settledUnchangedTotal++;
          if (outcome.settledUnchanged!) tally.settledUnchangedCount++;
        }

        resultsFile.writeAsStringSync(
          '$configName,$seed,${attack.name},${outcome.expected},'
          '${outcome.actual},${outcome.detected},${_boolCell(outcome.noImpact)},'
          '${_boolCell(outcome.forgedExcluded)},${_boolCell(outcome.honestUnaffected)},'
          '${_boolCell(outcome.settledUnchanged)}\n',
          mode: FileMode.append,
        );

        final hasImpact =
            outcome.noImpact == false ||
            outcome.forgedExcluded == false ||
            outcome.honestUnaffected == false ||
            outcome.settledUnchanged == false;
        if (!outcome.detected || hasImpact) {
          stdout.writeln(
            'FINDING: $configName seed=$seed ${attack.name}: '
            'expected=${outcome.expected} actual=${outcome.actual} '
            'detected=${outcome.detected} noImpact=${_boolCell(outcome.noImpact)} '
            'forgedExcluded=${_boolCell(outcome.forgedExcluded)} '
            'honestUnaffected=${_boolCell(outcome.honestUnaffected)} '
            'settledUnchanged=${_boolCell(outcome.settledUnchanged)}',
          );
        }
      }

      stdout.writeln(
        '$configName/${attack.name}: ${tally.detectedCount}/${tally.total} '
        'detected, ${tally.noImpactCount}/${tally.total} no impact, '
        '${tally.forgedExcludedCount}/${tally.forgedExcludedTotal} forgedExcluded, '
        '${tally.honestUnaffectedCount}/${tally.honestUnaffectedTotal} honestUnaffected, '
        '${tally.settledUnchangedCount}/${tally.settledUnchangedTotal} settledUnchanged '
        '(wanted $seedsPerAttack, found $done usable seeds)',
      );
    }
  }

  final summaryFile = File('../../docs/evaluation/rq4_security_summary.csv')
    ..writeAsStringSync(
      'config,attackType,total,detectedCount,detectedRate,'
      'noImpactCount,noImpactRate,'
      'forgedExcludedCount,forgedExcludedRate,'
      'honestUnaffectedCount,honestUnaffectedRate,'
      'settledUnchangedCount,settledUnchangedRate\n',
    );
  for (final configName in ['realistic', 'stress']) {
    for (final attack in AttackType.values) {
      final tally = tallies[configName]![attack]!;
      final detectedRate = tally.total == 0 ? 0.0 : tally.detectedCount / tally.total;
      final noImpactRate = tally.total == 0 ? 0.0 : tally.noImpactCount / tally.total;
      final forgedExcludedRate = tally.forgedExcludedTotal == 0
          ? 0.0
          : tally.forgedExcludedCount / tally.forgedExcludedTotal;
      final honestUnaffectedRate = tally.honestUnaffectedTotal == 0
          ? 0.0
          : tally.honestUnaffectedCount / tally.honestUnaffectedTotal;
      final settledUnchangedRate = tally.settledUnchangedTotal == 0
          ? 0.0
          : tally.settledUnchangedCount / tally.settledUnchangedTotal;
      summaryFile.writeAsStringSync(
        '$configName,${attack.name},${tally.total},${tally.detectedCount},'
        '${detectedRate.toStringAsFixed(4)},${tally.noImpactCount},'
        '${noImpactRate.toStringAsFixed(4)},${tally.forgedExcludedCount},'
        '${forgedExcludedRate.toStringAsFixed(4)},${tally.honestUnaffectedCount},'
        '${honestUnaffectedRate.toStringAsFixed(4)},${tally.settledUnchangedCount},'
        '${settledUnchangedRate.toStringAsFixed(4)}\n',
        mode: FileMode.append,
      );
    }
  }

  stdout.writeln('wrote ${resultsFile.path} and ${summaryFile.path}');
}

enum AttackType {
  signatureTamper,
  outsideKey,
  wrongRole,
  forgedCreate,
  chainTamper,
  equivocation,
  idConflict,
  nonCanonical,
  malformedSchema,
  overBudgetExpense,
  equivocationAtBudgetApprove,
  equivocationAtSettlementCut,
}

class _Tally {
  var total = 0;
  var detectedCount = 0;
  var noImpactCount = 0;
  var forgedExcludedTotal = 0;
  var forgedExcludedCount = 0;
  var honestUnaffectedTotal = 0;
  var honestUnaffectedCount = 0;
  var settledUnchangedTotal = 0;
  var settledUnchangedCount = 0;
}

/// `noImpact` is used by every attack type except the equivocation family,
/// which reports `forgedExcluded`/`honestUnaffected`/`settledUnchanged`
/// instead (see the equivocation note at the top of this file for why one
/// blended check is not precise enough there). Exactly one of the two shapes
/// is non-null for any given outcome.
class _AttackOutcome {
  const _AttackOutcome({
    required this.expected,
    required this.actual,
    required this.detected,
    this.noImpact,
    this.forgedExcluded,
    this.honestUnaffected,
    this.settledUnchanged,
  });

  final String expected;
  final String actual;
  final bool detected;
  final bool? noImpact;
  final bool? forgedExcluded;
  final bool? honestUnaffected;
  final bool? settledUnchanged;
}

String _boolCell(bool? value) => value == null ? '' : value.toString();

Future<_AttackOutcome?> _runAttack(
  AttackType type,
  WorkloadConfig config,
  int seed,
) async {
  // A fresh honest run every single attempt, never reused across attack
  // types or seeds: an attack mutates the live validator it is fed into
  // (chain-invalid ids, equivocation flags, stored conflicts), and reusing a
  // run would let one attack's evidence leak into the next check.
  final run = await generateWorkload(config, seed);
  // A large, odd offset so this RNG's sequence never lines up with the
  // generator's own seeded RNG (which also starts fresh from `Random(seed)`
  // for each run) — otherwise an attack's "random" id can come out byte-for-
  // byte identical to a real record's id, by sheer bad luck of matching
  // seeds, not by design.
  final rng = Random(seed * 2654435761 + 104729 + type.index);

  switch (type) {
    case AttackType.signatureTamper:
      return _signatureTamper(run);
    case AttackType.outsideKey:
      return _outsideKey(run, rng);
    case AttackType.wrongRole:
      return _wrongRole(run, seed, rng);
    case AttackType.forgedCreate:
      return _forgedCreate(run, rng);
    case AttackType.chainTamper:
      return _chainTamper(run, rng);
    case AttackType.equivocation:
      return _equivocation(run, rng);
    case AttackType.idConflict:
      return _idConflict(run, rng);
    case AttackType.nonCanonical:
      return _nonCanonical(run, seed);
    case AttackType.malformedSchema:
      return _malformedSchema(run, seed);
    case AttackType.overBudgetExpense:
      return _overBudgetExpense(run, rng);
    case AttackType.equivocationAtBudgetApprove:
      return _equivocationAtBudgetApprove(run, rng);
    case AttackType.equivocationAtSettlementCut:
      return _equivocationAtSettlementCut(run, rng);
  }
}

/// 1. Change a field of a real signed record, keep the old sig.
Future<_AttackOutcome?> _signatureTamper(WorkloadRun run) async {
  final receiving = run.manager.validator;
  final keys = {run.investor.key, run.manager.key};

  final candidates = receiving.usableRecords
      .where(
        (r) =>
            r.type == 'invest' ||
            r.type == 'sale' ||
            r.type == 'expense' ||
            r.type == 'withdraw_request',
      )
      .toList();
  if (candidates.isEmpty) return null;
  final original = candidates.first;

  final before = _dashboard(receiving, keys);
  final tampered = original.copyWith(
    body: {...original.body, 'amount': (original.body['amount'] as int) + 1},
  );
  final actual = await receiving.receiveText(canonicalJson(tampered.toJson()));
  final after = _dashboard(receiving, keys);

  return _AttackOutcome(
    expected: ReceiveOutcome.rejectedSignature.name,
    actual: actual.name,
    detected: actual == ReceiveOutcome.rejectedSignature,
    noImpact: _dashboardEquals(before, after),
  );
}

/// 2. A key that is not a partner signs a record.
Future<_AttackOutcome?> _outsideKey(WorkloadRun run, Random rng) async {
  final receiving = run.investor.validator;
  final keys = {run.investor.key, run.manager.key};
  final before = _dashboard(receiving, keys);

  final outsider = await generateEd25519KeyPair();
  final unsigned = _blankRecord(
    rng,
    run.partnershipId,
    outsider.publicKeyBase64Url,
    'sale',
    {'amount': 1000},
  );
  final signed = await signRecord(unsigned, outsider);
  final actual = await receiving.receiveText(canonicalJson(signed.toJson()));
  final after = _dashboard(receiving, keys);

  return _AttackOutcome(
    expected: ReceiveOutcome.rejectedMembership.name,
    actual: actual.name,
    detected: actual == ReceiveOutcome.rejectedMembership,
    noImpact: _dashboardEquals(before, after),
  );
}

/// 3. A real partner key signs a type it may not author. Cycles through the
/// three examples the spec gives, by seed, so all three get covered.
Future<_AttackOutcome?> _wrongRole(WorkloadRun run, int seed, Random rng) async {
  final receiving = run.manager.validator;
  final keys = {run.investor.key, run.manager.key};
  final before = _dashboard(receiving, keys);

  Record unsigned;
  Ed25519KeyPair signer;
  switch (seed % 3) {
    case 0: // manager signs invest (investor-only)
      unsigned = _blankRecord(rng, run.partnershipId, run.manager.key, 'invest', {
        'amount': 1000,
      });
      signer = run.manager.keyPair;
    case 1: // investor signs sale (manager-only)
      unsigned = _blankRecord(rng, run.partnershipId, run.investor.key, 'sale', {
        'amount': 1000,
      });
      signer = run.investor.keyPair;
    default: // manager requests a capital withdrawal (investor-only)
      unsigned = _blankRecord(
        rng,
        run.partnershipId,
        run.manager.key,
        'withdraw_request',
        {'amount': 1000, 'kind': 'capital'},
      );
      signer = run.manager.keyPair;
  }
  final signed = await signRecord(unsigned, signer);
  final actual = await receiving.receiveText(canonicalJson(signed.toJson()));
  final after = _dashboard(receiving, keys);

  return _AttackOutcome(
    expected: ReceiveOutcome.rejectedMembership.name,
    actual: actual.name,
    detected: actual == ReceiveOutcome.rejectedMembership,
    noImpact: _dashboardEquals(before, after),
  );
}

/// 4. Valid signature, different investor key, sent to a joining device with
/// pinned keys. The real create must still be accepted afterwards.
Future<_AttackOutcome?> _forgedCreate(WorkloadRun run, Random rng) async {
  // A brand-new "joining device" validator, pinned to the real keys — not a
  // live device from the run, which already has a create. This is the
  // device the forged create is actually trying to fool.
  final joining = Validator(
    pinnedInvestorKey: run.investor.key,
    pinnedManagerKey: run.manager.key,
  );

  final fakeInvestor = await generateEd25519KeyPair();
  final fakeId = _uuidV4(rng);
  final forgedUnsigned = Record(
    v: 1,
    id: fakeId,
    partnership: fakeId,
    author: fakeInvestor.publicKeyBase64Url,
    seq: 1,
    prevHash: '0' * 64,
    type: 'partnership_create',
    body: {
      'investor': fakeInvestor.publicKeyBase64Url,
      'manager': run.manager.key,
      'ratio': {'investor': 60, 'manager': 40},
      'currency': 'PKR',
    },
    refersTo: null,
    note: 'rq4-forged-create',
    time: '2026-01-01T00:00:00Z',
    sig: '',
  );
  final forgedSigned = await signRecord(forgedUnsigned, fakeInvestor);
  final forgedActual = await joining.receiveText(canonicalJson(forgedSigned.toJson()));

  final realCreate = run.investorLedger.firstWhere(
    (r) => r.type == 'partnership_create',
  );
  final realActual = await joining.receiveText(canonicalJson(realCreate.toJson()));

  final detected =
      forgedActual == ReceiveOutcome.rejectedMembership &&
      realActual == ReceiveOutcome.accepted;

  return _AttackOutcome(
    expected: 'rejectedMembership;accepted',
    actual: '${forgedActual.name};${realActual.name}',
    detected: detected,
    // The forged create was never stored (rejectedMembership means nothing
    // was added), so there is nothing it could have impacted.
    noImpact: true,
  );
}

/// 5. The real author signs its next record with a wrong prevHash.
Future<_AttackOutcome?> _chainTamper(WorkloadRun run, Random rng) async {
  final receiving = run.manager.validator;
  final keys = {run.investor.key, run.manager.key};
  final before = _dashboard(receiving, keys);

  final authorKey = run.investor.key;
  final height = receiving.ledger.versionVector()[authorKey];
  if (height == null) return null;

  final unsigned = Record(
    v: 1,
    id: _uuidV4(rng),
    partnership: run.partnershipId,
    author: authorKey,
    seq: height + 1,
    prevHash: _hex64Of(rng), // almost certainly not the real chain head's hash
    type: 'invest',
    body: {'amount': 1000},
    refersTo: null,
    note: 'rq4-chain-tamper',
    time: '2026-01-01T00:00:00Z',
    sig: '',
  );
  final signed = await signRecord(unsigned, run.investor.keyPair);
  final actual = await receiving.receiveText(canonicalJson(signed.toJson()));
  final after = _dashboard(receiving, keys);

  final detected =
      actual == ReceiveOutcome.chainInvalid &&
      receiving.chainInvalidIds.contains(signed.id);

  return _AttackOutcome(
    expected: ReceiveOutcome.chainInvalid.name,
    actual: actual.name,
    detected: detected,
    noImpact: _dashboardEquals(before, after),
  );
}

/// 6. The real author signs two different records with the same seq. Also
/// checks, through an in-memory relay, that the other partner's device
/// receives both versions and flags the same author. The targeted seq here
/// is simply the author's current chain head — see `_equivocationAttack` for
/// the shared mechanics, and the two targeted variants below for seqs chosen
/// to land exactly on a budget approval or a settlement's cut.
Future<_AttackOutcome?> _equivocation(WorkloadRun run, Random rng) async {
  final receiving = run.manager.validator;
  final authorKey = run.investor.key;
  final seqHeight = receiving.ledger.versionVector()[authorKey];
  if (seqHeight == null) return null;
  return _equivocationAttack(run, rng, authorKey: authorKey, targetSeq: seqHeight);
}

/// 11. The investor equivocates at the exact seq of their own `approve` of
/// one of the manager's budget_proposals. If this is detected AND leaves the
/// manager's own expenses under that budget unaffected, consent-dropping by
/// quarantine is not happening here; if `honestUnaffected` comes back false,
/// it is.
Future<_AttackOutcome?> _equivocationAtBudgetApprove(WorkloadRun run, Random rng) async {
  final receiving = run.manager.validator;
  final authorKey = run.investor.key;

  final usable = receiving.usableRecords.toList();
  int? targetSeq;
  for (final budget in usable.where((r) => r.type == 'budget_proposal')) {
    final approve = usable.where(
      (r) => r.type == 'approve' && r.refersTo == budget.id && r.author == authorKey,
    );
    if (approve.isNotEmpty) {
      targetSeq = approve.first.seq;
      break;
    }
  }
  if (targetSeq == null) return null; // no investor approve-of-budget this seed; skip

  return _equivocationAttack(run, rng, authorKey: authorKey, targetSeq: targetSeq);
}

/// 12. The investor equivocates at the exact seq of one of their own records
/// that sits inside an already-effective settlement's cut (the cut's own
/// named investor seq, which `cutIsHeld` must find in the usable records for
/// the settlement to stay effective). If `settledUnchanged` comes back
/// false, quarantining that seq un-held the cut and reverted a settled
/// period back to not-decided.
Future<_AttackOutcome?> _equivocationAtSettlementCut(WorkloadRun run, Random rng) async {
  final receiving = run.manager.validator;
  final authorKey = run.investor.key;
  final keys = {run.investor.key, run.manager.key};

  final usable = receiving.usableRecords.toList();
  final effectiveness = computeEffective(usable, partnershipKeys: keys);

  int? targetSeq;
  for (final settlement in effectiveness.settlements) {
    if (settlement.state != SettlementState.effective) continue;
    final investorSeq = settlement.cut[authorKey];
    if (investorSeq != null && investorSeq > 0) {
      targetSeq = investorSeq;
      break;
    }
  }
  if (targetSeq == null) return null; // no effective settlement covering the investor this seed

  return _equivocationAttack(run, rng, authorKey: authorKey, targetSeq: targetSeq);
}

/// Shared equivocation mechanics for attack types 6, 11 and 12: duplicate the
/// named author's record at `targetSeq` with different content, feed the
/// forgery into the manager's live validator, and measure the three
/// precise checks described at the top of this file instead of a single
/// blended noImpact (quarantine is deliberate; its collateral reach on OTHER
/// records is the open question).
Future<_AttackOutcome?> _equivocationAttack(
  WorkloadRun run,
  Random rng, {
  required String authorKey,
  required int targetSeq,
}) async {
  final receiving = run.manager.validator;
  final other = run.investor.validator;
  final keys = {run.investor.key, run.manager.key};
  final honestAuthorKey = authorKey == run.investor.key ? run.manager.key : run.investor.key;

  final original = receiving.ledger.records.firstWhere(
    (r) => r.author == authorKey && r.seq == targetSeq,
  );
  final authorKeyPair = authorKey == run.investor.key
      ? run.investor.keyPair
      : run.manager.keyPair;

  // Baselines, captured before the attack: every honest-partner record's own
  // effective/expense status, and the cut of every settlement that is
  // currently effective.
  final beforeEffectiveness = computeEffective(
    receiving.usableRecords.toList(),
    partnershipKeys: keys,
  );
  final honestRecordIds = receiving.usableRecords
      .where((r) => r.author == honestAuthorKey)
      .map((r) => r.id)
      .toList();
  final beforeHonestEffective = {
    for (final id in honestRecordIds) id: beforeEffectiveness.effectiveIds.contains(id),
  };
  final beforeHonestExpense = {
    for (final id in honestRecordIds) id: beforeEffectiveness.expenseStatus[id],
  };
  final beforeEffectiveSettlements = {
    for (final s in beforeEffectiveness.settlements)
      if (s.state == SettlementState.effective) s.record.id: s.cut,
  };

  // Changing only `note` (never part of a type's body) keeps the forged
  // record schema-valid for any record type, including partnership_create.
  final forgedUnsigned = original.copyWith(
    id: _uuidV4(rng),
    note: 'rq4-equivocation',
  );
  final forged = await signRecord(forgedUnsigned, authorKeyPair);
  final forgedText = canonicalJson(forged.toJson());

  final actual = await receiving.receiveText(forgedText);
  final receivingFlagged =
      actual == ReceiveOutcome.equivocating &&
      receiving.equivocatingFromSeq[authorKey] == targetSeq;

  final relay = RelaySim();
  relay.upload(canonicalJson(original.toJson()));
  relay.upload(forgedText);
  final reply = relay.sync(clientVector: other.ledger.versionVector(), uploads: const []);
  for (final text in [...reply.records, ...reply.conflicts]) {
    await other.receiveText(text);
  }
  final otherFlagged = other.equivocatingFromSeq[authorKey] == targetSeq;

  final afterEffectiveness = computeEffective(
    receiving.usableRecords.toList(),
    partnershipKeys: keys,
  );

  final forgedExcluded = !receiving.usableRecords.any(
    (r) => r.author == authorKey && r.seq == targetSeq,
  );

  var honestUnaffected = true;
  for (final id in honestRecordIds) {
    final afterEffective = afterEffectiveness.effectiveIds.contains(id);
    final afterExpense = afterEffectiveness.expenseStatus[id];
    if (beforeHonestEffective[id] != afterEffective ||
        beforeHonestExpense[id] != afterExpense) {
      honestUnaffected = false;
      break;
    }
  }

  var settledUnchanged = true;
  for (final entry in beforeEffectiveSettlements.entries) {
    final afterStatus = afterEffectiveness.settlements.firstWhere(
      (s) => s.record.id == entry.key,
    );
    if (afterStatus.state != SettlementState.effective ||
        !_mapEquals(afterStatus.cut, entry.value)) {
      settledUnchanged = false;
      break;
    }
  }

  return _AttackOutcome(
    expected: 'equivocating;flaggedByOther',
    actual: '${actual.name};flaggedByOther=$otherFlagged',
    detected: receivingFlagged && otherFlagged,
    forgedExcluded: forgedExcluded,
    honestUnaffected: honestUnaffected,
    settledUnchanged: settledUnchanged,
  );
}

/// 7. A new record reuses an existing record's id with different content.
Future<_AttackOutcome?> _idConflict(WorkloadRun run, Random rng) async {
  final receiving = run.manager.validator;
  final keys = {run.investor.key, run.manager.key};

  final authorKey = run.investor.key;
  final height = receiving.ledger.versionVector()[authorKey];
  if (height == null) return null;

  final head = receiving.ledger.records.firstWhere(
    (r) => r.author == authorKey && r.seq == height,
  );
  final before = _dashboard(receiving, keys);

  // An otherwise-correct continuation of the author's chain (right seq,
  // right prevHash, right role), but reusing an existing id — the conflict
  // is purely about the id, nothing else.
  final unsigned = Record(
    v: 1,
    id: head.id,
    partnership: run.partnershipId,
    author: authorKey,
    seq: height + 1,
    prevHash: recordHash(head.toJson()),
    type: 'invest',
    body: {'amount': 1000},
    refersTo: null,
    note: 'rq4-id-conflict',
    time: '2026-01-01T00:00:00Z',
    sig: '',
  );
  final signed = await signRecord(unsigned, run.investor.keyPair);
  final actual = await receiving.receiveText(canonicalJson(signed.toJson()));
  final after = _dashboard(receiving, keys);

  final detected =
      actual == ReceiveOutcome.idConflict &&
      receiving.ledger.conflicts.any((r) => r.id == head.id && r.seq == height + 1);

  return _AttackOutcome(
    expected: ReceiveOutcome.idConflict.name,
    actual: actual.name,
    detected: detected,
    noImpact: _dashboardEquals(before, after),
  );
}

/// 8. Valid JSON, but not canonical bytes: extra whitespace, a duplicate
/// key, or keys out of sorted order (cycled by seed).
Future<_AttackOutcome?> _nonCanonical(WorkloadRun run, int seed) async {
  final receiving = run.manager.validator;
  final keys = {run.investor.key, run.manager.key};
  final original = receiving.usableRecords.first;
  final before = _dashboard(receiving, keys);

  final canonicalText = canonicalJson(original.toJson());
  final String brokenText;
  switch (seed % 3) {
    case 0:
      brokenText = canonicalText.replaceFirst(':', ': '); // extra space
    case 1:
      // A duplicate "v" key, appended just before the closing brace ("v" is
      // always the last key in canonical order — the only field name whose
      // first letter sorts after every other field's). Valid JSON (the
      // decoder keeps the last occurrence), but the re-encoded bytes then
      // no longer match what arrived.
      brokenText =
          '${canonicalText.substring(0, canonicalText.length - 1)},"v":1}';
    default:
      // dart:convert's default encoder keeps the record's own field order
      // (v, id, partnership, ...), which is not the canonical, sorted order.
      brokenText = jsonEncode(original.toJson());
  }

  final actual = await receiving.receiveText(brokenText);
  final after = _dashboard(receiving, keys);

  return _AttackOutcome(
    expected: ReceiveOutcome.rejectedNotCanonical.name,
    actual: actual.name,
    detected: actual == ReceiveOutcome.rejectedNotCanonical,
    noImpact: _dashboardEquals(before, after),
  );
}

/// 9. A required field is missing, or has the wrong type (cycled by seed).
Future<_AttackOutcome?> _malformedSchema(WorkloadRun run, int seed) async {
  final receiving = run.manager.validator;
  final keys = {run.investor.key, run.manager.key};
  final original = receiving.usableRecords.first;
  final before = _dashboard(receiving, keys);

  final json = Map<String, dynamic>.from(original.toJson());
  if (seed % 2 == 0) {
    json.remove('prevHash');
  } else {
    json['seq'] = json['seq'].toString(); // seq must be an int, not a string
  }
  final text = canonicalJson(json);

  final actual = await receiving.receiveText(text);
  final after = _dashboard(receiving, keys);

  return _AttackOutcome(
    expected: ReceiveOutcome.rejectedSchema.name,
    actual: actual.name,
    detected: actual == ReceiveOutcome.rejectedSchema,
    noImpact: _dashboardEquals(before, after),
  );
}

/// 10. A valid, correctly-signed and correctly-chained expense that breaks a
/// real, currently-effective budget.
Future<_AttackOutcome?> _overBudgetExpense(WorkloadRun run, Random rng) async {
  final receiving = run.investor.validator;
  final keys = {run.investor.key, run.manager.key};

  final usable = receiving.usableRecords.toList();
  final effectiveness = computeEffective(usable, partnershipKeys: keys);

  String? budgetId;
  int? remaining;
  String? grantee;
  for (final record in usable) {
    if (record.type != 'budget_proposal' || !effectiveness.isEffective(record)) {
      continue;
    }
    final amount = record.body['amount'] as int;
    final used = effectiveness.budgetUsed[record.id] ?? 0;
    final left = amount - used;
    if (left < 0) continue;
    budgetId = record.id;
    remaining = left;
    grantee = record.body['grantee'] as String;
    break;
  }
  if (budgetId == null) return null; // no active budget this seed; skip

  final granteeKeyPair = grantee == run.manager.key
      ? run.manager.keyPair
      : run.investor.keyPair;
  final height = receiving.ledger.versionVector()[grantee] ?? 0;
  final head = height == 0
      ? null
      : usable.firstWhere((r) => r.author == grantee && r.seq == height);

  final before = _dashboard(receiving, keys);

  final unsigned = Record(
    v: 1,
    id: _uuidV4(rng),
    partnership: run.partnershipId,
    author: grantee!,
    seq: height + 1,
    prevHash: head == null ? '0' * 64 : recordHash(head.toJson()),
    type: 'expense',
    body: {'amount': remaining! + 1000},
    refersTo: budgetId,
    note: 'rq4-over-budget',
    time: '2026-01-01T00:00:00Z',
    sig: '',
  );
  final signed = await signRecord(unsigned, granteeKeyPair);
  final actual = await receiving.receiveText(canonicalJson(signed.toJson()));
  final after = _dashboard(receiving, keys);

  final newEffectiveness = computeEffective(
    receiving.usableRecords.toList(),
    partnershipKeys: keys,
  );
  final status = newEffectiveness.expenseStatus[signed.id];

  final detected = actual == ReceiveOutcome.accepted && status == ExpenseStatus.overBudget;

  return _AttackOutcome(
    expected: 'accepted;overBudget',
    actual: '${actual.name};${status?.name ?? "none"}',
    detected: detected,
    noImpact: _dashboardEquals(before, after),
  );
}

Record _blankRecord(
  Random rng,
  String partnershipId,
  String author,
  String type,
  Map<String, dynamic> body,
) {
  return Record(
    v: 1,
    id: _uuidV4(rng),
    partnership: partnershipId,
    author: author,
    seq: 1,
    prevHash: '0' * 64,
    type: type,
    body: body,
    refersTo: null,
    note: 'rq4-attack',
    time: '2026-01-01T00:00:00Z',
    sig: '',
  );
}

/// A record id in the shape core requires (version 4, variant 8/9/a/b — see
/// `validator.dart`'s `_uuidV4`), drawn from a seeded RNG for reproducibility.
String _uuidV4(Random rng) {
  const hex = '0123456789abcdef';
  final chars = List<String>.generate(32, (_) => hex[rng.nextInt(16)]);
  chars[12] = '4';
  chars[16] = hex[8 + rng.nextInt(4)]; // 8, 9, a or b
  final s = chars.join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}'
      '-${s.substring(16, 20)}-${s.substring(20, 32)}';
}

String _hex64Of(Random rng) {
  const hex = '0123456789abcdef';
  return List<String>.generate(64, (_) => hex[rng.nextInt(16)]).join();
}

Dashboard _dashboard(Validator validator, Set<String> partnershipKeys) =>
    buildDashboard(validator.usableRecords.toList(), partnershipKeys: partnershipKeys);

bool _dashboardEquals(Dashboard a, Dashboard b) {
  return a.money.capital == b.money.capital &&
      a.money.cashBalance == b.money.cashBalance &&
      a.money.result == b.money.result &&
      a.money.profitPaid == b.money.profitPaid &&
      _mapEquals(a.money.budgetLeft, b.money.budgetLeft) &&
      a.ratio?.ratio.investor == b.ratio?.ratio.investor &&
      a.ratio?.ratio.manager == b.ratio?.ratio.manager &&
      a.shares?.investor == b.shares?.investor &&
      a.shares?.manager == b.shares?.manager &&
      a.ratioChanged == b.ratioChanged &&
      a.partnershipStatus == b.partnershipStatus;
}

bool _mapEquals(Map<String, int> a, Map<String, int> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
