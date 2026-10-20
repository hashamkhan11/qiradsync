# Evaluation workload generator

Phase 8 needs real numbers, not guesses: sync size, coordination cost, verification time, all
measured against runs that look like an actual two-partner Mudaraba business, not a toy. The
`packages/evaluation` package builds those runs by driving `qirad_core`'s real rules — the same
`buildRecord`, `signRecord`, `proposalRefusal`, `answerEligibility` and `answerConsent` the app
calls — through a seeded, hourly-tick simulation of one investor and one manager phone.

Every run is reproducible from `(config, seed)` alone: one `Random(seed)` drives every sampled
amount, delay and decision, and nothing in the generator reads the system clock (hard rule 3 —
simulated `time` fields are built from the tick counter, never `DateTime.now()`).

## Research questions

Phase 8 answers four questions, each with its own tool and output files, so a result can always be
traced back to how it was produced.

### RQ1 — Correctness of delta sync

**Question:** does the CRDT merge and delta-sync protocol converge to identical, correct ledgers on
both devices, under realistic and adversarial network conditions, without ever recalculating a
closed settlement?

**Method:** several hundred seeded runs per config, 90 days each (`tool/rq1_correctness.dart`).
Every run is checked two independent ways — `liveConverged` (the two devices' own validators,
exactly as the simulation left them, after a forced final mutual-online quiet window) and
`backupConverged` (`_resyncThroughRelay`: both devices' finished record sets replayed through the
real delta protocol from scratch, once, at the end) — and `passed` requires both, so a passing
backup can never hide a failing live check. See "Simulation simplifications" and "Threats to
validity" below for what each check does and does not cover.

**Metrics:** `liveConverged`, `backupConverged`, `identicalRecords`, `dashboardMatch`,
`settlementStable`, `budgetSafe`, `noFalseAlarms`, `nonTrivial` (at least one effective settlement
and one expense), `settlementsEffective`, `reversals`.

**Output:** `docs/evaluation/rq1_correctness.csv` (one row per run), `rq1_failures.csv` (one row per
failing check, with the seed and the first differing record or value, so it is reproducible).

### RQ2 — Coordination cost

**Question:** what share of writes are coordination-free versus need the other partner's consent,
and how much does one round of coordination actually cover?

**Method:** the same seeded runs (`tool/rq2_coordination.dart`), classifying every record into
`coordinationFree` (`sale`, `expense`, `invest`, and a self-reversal), `consentProposals`
(`budget_proposal`, `ratio_proposal`, `settlement`, `withdraw_request`, and a reversal of the other
partner's record), or `responses` (`approve`/`reject` — the actual coordination cost: actions the
*other* partner had to take). `partnership_create` is reported separately (always exactly 1 per
run) rather than folded into the ratio. `expensesPerBudgetApproval` reports how many stand-alone
expense writes one budget-approval round of coordination amortizes over.

**Metrics:** `coordinationFree`/`consentProposals`/`responses` counts and fraction, per run and per
month; `expensesPerBudgetApproval`.

**Output:** `docs/evaluation/rq2_coordination.csv` (per run), `rq2_coordination_summary.csv`
(aggregated per config).

### RQ3 — Performance vs. ledger size

**Question:** how does the per-call cost of the app's full-ledger recompute functions
(`approvalsInbox`, `computeEffective`, `buildDashboard`) grow as the ledger grows, and is that
acceptable at realistic sizes?

**Method:** cached fixtures (`tool/generate_fixtures.dart`), planned at roughly 100 / 1,000 /
10,000 records (about 1 month / 12 months / 10 years of `realistic`) but the 10-year generation did
not finish (see "Run lengths"), so the ladder actually reached is 1 month / 12 months / 3 years / 5
years (about 65 / 731 / 2,268 / 3,751 records); read back as size-N prefixes in authorship order,
`tool/benchmark_recalc.dart` times each function in isolation, as a compiled binary (no JIT warm-up
noise), with a warm-up phase and enough repetitions that the median is a real element, not an
average.

**Metrics:** median milliseconds per call, for each of the three functions, at each size.

**Output:** fixtures cached under `packages/evaluation/data/` (gitignored, regenerable);
`benchmark_recalc.dart`'s printed table, recorded into this README's "Where the time goes" table.

### RQ3b — Sync payload size

**Question:** at realistic ledger sizes, how many bytes does an ordinary delta sync carry, compared
to the full-state download a brand-new device would need? (This is `docs/plan.md`'s "measure sync
size (full vs delta) for 100 / 1,000 / 10,000 records" item — a different question from RQ3's call
*time*, so it gets its own tool and table rather than being folded into RQ3's numbers.)

**Method:** `tool/rq3b_sync_size.dart`, reusing the same cached fixture as RQ3 (no new simulation
runs). "Full" is the canonical JSON (spec 7.2) of every record in a size-N prefix — what a new
device's very first sync downloads. "Delta" is the version vector a syncing device sends (spec 7.1)
plus the records the relay sends back for one ordinary sync. The fixture's `events` log only
records when each record was authored, not when any sync call ran or what it carried, so "one
ordinary sync" is approximated as "one simulated day": the records authored on a given day stand in
for what the next sync would pick up. This is a proxy over authorship timing, not a replay of real
sync calls, and is reported as such. The **median** across days (not the mean) is used for both the
record count and the byte count, each computed separately from the real per-day data — not one
derived from the other — so "a typical sync" is an actual day that happened, not an average no day
matches.

**Metrics:** full-state bytes, delta record count and bytes (median), version-vector bytes, and the
full/delta ratio, at each size.

**Output:** `docs/evaluation/rq3_sync_size.csv`.

### RQ4 — Security

**Question:** does the system detect every attack attempted against it, and does no attack change
the honest partner's own numbers?

**Method:** `tool/rq4_security.dart`, about 50 seeds per attack type per config (see "Run lengths"
for the actual sizes used). Each run starts from an honest generated run, injects one crafted
attack record into the receiving device, and checks `detected` (the validator's actual outcome
matches the expected one). For the 9 ordinary attacks (1–9 below), it also checks `noImpact` (the
receiving device's dashboard numbers stay identical to the honest run's own — only evidence/flags
may differ). The 3 equivocation-family attacks (6, 11, 12) use three separate checks instead of
one blended `noImpact`, because an equivocating author's quarantine is global and retroactive
(spec §6.4) and a single pass/fail number hid exactly where it bites — see "Findings" below:

- `forgedExcluded` — the forged version never appears in any computed number anywhere.
- `honestUnaffected` — every record written by the *other*, honest partner keeps the same
  effective/expense status it had before the attack.
- `settledUnchanged` — every settlement that was already `effective` before the attack stays
  `effective`, with an identical `cut`, after it.

**Attack types and expected outcomes:**

| # | Attack | Expected outcome |
|---|---|---|
| 1 | Signature tamper — change a field of a real signed record, keep the old signature | `rejectedSignature` |
| 2 | Outside key — a non-partner key signs a record | `rejectedMembership` |
| 3 | Wrong role — a real partner key signs a type it may not author (manager signs `invest`, investor signs `sale`, manager requests a capital withdrawal) | `rejectedMembership` |
| 4 | Forged `partnership_create` — valid signature, different investor key, sent to a device with pinned keys | `rejectedMembership`; the real create is still accepted afterwards |
| 5 | Chain tamper — the real author signs its next record with a wrong `prevHash` | `chainInvalid` |
| 6 | Equivocation (generic) — the real author signs two different records at the same `seq` as its current chain head (including rewriting and re-signing an old one) | `equivocating`; the other partner, receiving both versions through `RelaySim`, also flags the author |
| 7 | Id conflict — a new record reuses an existing id with different content | `idConflict` |
| 8 | Non-canonical bytes (extra spaces, wrong key order, duplicate keys) / malformed schema | `rejectedNotCanonical` / `rejectedSchema` |
| 9 | Over-budget expense signed by a dishonest manager (valid signature, breaks the budget) | stored as evidence, status `overBudget`, excluded from all computed numbers |
| 10 | — *(reserved; see note below)* | |
| 11 | Equivocation at budget approve — the investor equivocates at the exact `seq` of their own `approve` of a `budget_proposal` | `equivocating`, detected both sides, but see "Findings" |
| 12 | Equivocation at settlement cut — the investor equivocates at a `seq` already covered by an `effective` settlement's `cut` | `equivocating`, detected both sides, but see "Findings" |

(Numbering follows `AttackType`'s declaration order in `rq4_security.dart`; there is no attack
#10 — the enum has 12 values, with the two targeted equivocation variants added after the original
9.)

Any attack that is not detected, or that changes the honest partner's numbers, is a finding to
report, not a result to hide. For the two targeted equivocation variants, that finding is
confirmed and documented below rather than hidden — see "Findings."

**Output:** `docs/evaluation/rq4_security.csv` (config, seed, attackType, expectedOutcome,
actualOutcome, detected, noImpact, forgedExcluded, honestUnaffected, settledUnchanged — the last
four columns are blank except where that check applies), `rq4_security_summary.csv`
(counts and rates for all four checks, per attack type and config).

## Findings

### Quarantining an equivocator can undo the honest partner's own consent and revert a settled period

**What happens:** spec §6.4's equivocation rule, as built in `Validator`, excludes *every* record
an equivocating author wrote from the contested `seq` onward, forever — not just the forged
record. This is correct and necessary for the forged record itself, but it is global by author,
not by record identity, so it also removes any *real*, honestly-signed record from that author at
or after that seq. Two cases were targeted to confirm this has real effect:

- **Budget approve:** if the investor equivocates at the seq of their own `approve` of a
  `budget_proposal`, that approve disappears from `usableRecords`. `decideApprovals` recomputes the
  budget's `Decision` fresh every call, so the budget reverts to `pending`, and every manager
  expense written against it — expenses the manager wrote in good faith while the budget was
  genuinely approved — falls through `computeEffective` to `ExpenseStatus.noEffectiveBudget` and
  stops counting.
- **Settlement cut:** if the investor equivocates at a seq inside an already-`effective`
  settlement's `cut`, the settlement's own status reverts from `effective` to `waiting`
  (`settlementStatuses` also recomputes fresh every call) — a period that was already closed and
  paid out un-settles itself, even though the cut's own seq numbers do not change.

**Evidence** (2026-10-19, commit `f9b94ed`, 50 seeds/attack/config, 90-day workloads, both
configs — see `rq4_security_summary.csv`):

| config    | attack type                  | detected | forgedExcluded | honestUnaffected | settledUnchanged |
|-----------|-------------------------------|----------|----------------|-------------------|-------------------|
| realistic | equivocation (generic)        | 50/50    | 50/50          | 19/50             | 47/50             |
| realistic | equivocationAtBudgetApprove    | 50/50    | 50/50          | 0/50              | 0/50              |
| realistic | equivocationAtSettlementCut    | 50/50    | 50/50          | 0/50              | 0/50              |
| stress    | equivocation (generic)        | 50/50    | 50/50          | 26/50             | 48/50             |
| stress    | equivocationAtBudgetApprove    | 50/50    | 50/50          | 0/50              | 1/50              |
| stress    | equivocationAtSettlementCut    | 50/50    | 50/50          | 0/50              | 0/50              |

Both targeted variants hit `honestUnaffected = 0` on every seed, in both configs, and
`settledUnchanged = 0` on all but one (`stress`/`equivocationAtBudgetApprove`, 1/50) — a
deterministic, structural consequence of how the quarantine is defined, not a rare or
seed-dependent event. The untargeted, generic equivocation attack (which usually lands on a seq
the honest partner never specifically relied on) shows the same effect only part of the time
(19/50–26/50 "unaffected"), consistent with this being about *which* seq is hit, not a different
mechanism.

**One example (realistic config, seed 1):**

- *Budget approve* — the investor's `approve` of a Rs 27,428.80 budget sat at seq 3. Quarantining
  the investor from seq 3 flipped all 15 of the manager's expense records written against that
  budget from `effective=true` (`ExpenseStatus.valid`) to `effective=false`
  (`ExpenseStatus.noEffectiveBudget`) — none of those 15 records were touched or forged; they
  changed purely because the approval they depended on vanished. The dashboard's `cashBalance`
  moved by +Rs 1,675,009.40 and `result` by +Rs 81,553.00, both only because real spending silently
  stopped being counted.
- *Settlement cut* — an already-`effective` settlement (`cut = {investor: 4, manager: 68}`,
  `profitPaid` = Rs 874,432.13) reverted to `waiting` the moment the investor was quarantined from
  a seq inside that cut, even though the cut's own numbers did not change. `profitPaid` for that
  period fell to Rs 0 — a period that had already paid out profit-sharing stopped being settled at
  all.

**What still holds:** `detected` and `forgedExcluded` are 15/15 in every row above. The system
always correctly identifies the equivocating author — both this device directly, and the other
partner independently via `RelaySim` cross-checking — and the forged content itself never appears
in any computed number. What breaks is strictly collateral: legitimate records the honest partner
wrote, and periods already closed, before the forgery was ever sent.

**Decision:** not fixed in core for this phase (scope freeze) — `qirad_core`'s quarantine rule
stays exactly as spec §6.4 defines it. See `docs/decisions.md`, 2026-10-16, for the full write-up,
reasoning, and future-work design options (never quarantine inside an effective settlement's cut;
keep the first-received version at a contested seq for consent already relied on; freeze
consent-dependent effects at the point of reliance).

## The two configs

`WorkloadConfig.realistic` models a believable business day. `WorkloadConfig.stress` keeps the
same business (same amounts, same record types) but turns up everything that exercises the CRDT
and consent rules — longer offline gaps, more mistakes, more ratio changes, worse network
behaviour — so refusals, reversals, chain gaps and staleness in the data come from genuine
pressure on the rules, not from a lucky seed.

| Field | realistic | stress | Reason |
|---|---|---|---|
| `initialInvestment` | Rs 500,000–2,000,000 | same | A small Mudaraba business's typical starting capital — enough to fund real trade, not a token amount. |
| `additionalInvestmentDailyChance` | ~once/60 days | same | An investor occasionally tops up capital mid-year, but it is not a routine event. |
| `additionalInvestmentAmount` | Rs 500,000–2,000,000 | same | A top-up is a real capital injection, not a small adjustment. |
| `salesPerDay` | 1.5 | same | A manager records daily or per-deal totals, not every small sale, so this is a handful a day. |
| `saleAmount` | Rs 2,000–100,000 | same | A daily or per-deal total for a small trading business. |
| `saleMistakeRate` | 1% | 5% | **Models reality** at 1%: mistakes happen, but rarely. **Stress** raises it to exercise reversal handling often. |
| `expensesPerDay` | 0.8 | same | Fewer, larger outflows against an open budget than sales. |
| `expenseAmount` | Rs 200–30,000 | same | Ordinary running costs up to an occasional large purchase. |
| `expenseMistakeRate` | 3% | 10% | **Models reality** at 3% (expenses are checked against a budget at entry, so slightly more error-prone than sales). **Stress** raises it to 10%. |
| `reversalDelayHours` | 1–72h | same | A mistake is noticed and fixed within hours to a few days, not instantly. |
| `budgetRenewalThreshold` | 20% left | same | The manager proposes a new budget once the current one is nearly spent — a business condition, not a timer, so overBudget/renewal refusals reflect the system (the user's explicit requirement). |
| `budgetCoverageDays` | 14 days | same | A new budget is sized to cover about two weeks of expected expenses — a realistic amount, not an arbitrary round number. |
| `ratioChangeIntervalDays` | ~365 days | ~45 days | **Models reality** at ~once a year: ratios are rarely renegotiated. **Stress** drops it to ~45 days to exercise the rule often. |
| `ratioEffectiveFromLeadDays` | 3–7 days | same | A new ratio takes effect after a short real negotiation lead time, not instantly. |
| `settlementIntervalDays` | ~30 days | same | The natural monthly accounting cycle for this kind of partnership (spec 6.5). |
| `settlementRejectChance` | 10% | same | A partner disputing the numbers is uncommon but real, so both outcomes appear in the data. |
| `answerDelayHours` | 1–6h | 24–72h | **Models reality** at 1–6h: close to the offline window itself. **Stress** widens it to 24–72h to make staleness and reordering more likely to actually occur. |
| `profitWithdrawalChance` | 60% | same | A common, but not universal, next step once a settlement confirms profit. |
| `profitWithdrawalFraction` | 10%–60% of settled share | same | Partners rarely withdraw either a token amount or everything at once. |
| `capitalWithdrawalDailyChance` | ~once/90 days | same | The investor rarely pulls capital out mid-partnership. |
| `capitalWithdrawalFraction` | 5%–20% of cash balance | same | A partial draw-down, not a full exit. |
| `shortOfflinePeriodsPerDay` | 1–3 | 1–2 | A phone goes offline a few short times a day under normal use, in both configs. |
| `shortOfflinePeriodHours` | 1–6h | same | A work gap or overnight — identical in both configs; only the long weekly episode below differs. |
| `longOfflineEpisodeChancePerWeek` | 0 (never) | 1.0 (about once a week) | **Models reality**: a connection this bad never happens. **Stress** adds a genuinely dropped connection roughly once a week, on top of the daily gaps, to force long divergence before sync — without making the device permanently unreachable (periods never overlap; see "Online schedule" below). |
| `longOfflineEpisodeDays` | n/a | 1–3 days | Length of the weekly episode when it fires. **Stress** only. |
| `relayDelaySeconds` | 0–30s | 0–300s | Modelled as a holdback on the author's own upload (a record is not offered as a sync candidate until this much simulated time has passed), not as latency before delivery to the recipient — the recipient only ever learns of it once it actually reaches the relay. **Models reality** at a normal connection's delay. **Stress** models a poor connection. |
| `duplicateRate` | 2% | 10% | Chance a device's sync call is immediately repeated for the same hour (a retried sync re-sending records the relay already has), to exercise de-duplication (`ReceiveOutcome.duplicateIgnored`). **Stress** raises this to test it harder, not because real syncs duplicate this often. |
| `reorderChance` | 0% | 15% | Chance a sync call's received batch is fed to the validator in shuffled order instead of the relay's guaranteed per-author seq order, to exercise the chain-gap buffer. **realistic** uses 0%: a well-behaved client never does this on its own, so there is nothing to model at a low rate. **Stress** raises it to test the buffer under a condition that should never occur in practice. |

**Online schedule:** each device's online/offline hours are precomputed once per run. Day 0 is
always online for both devices (the partners set the partnership up in person, with the QR key
exchange), and offline periods — both the short daily ones and, in `stress`, the long weekly
episode — never overlap an hour already marked offline, so they cannot stack into a longer outage
than either one is meant to model on its own. Each run records both devices' actual online
fraction (`WorkloadRun.onlineFractionInvestor`/`onlineFractionManager`); the `onlineFraction*`
columns in `rq1_correctness.csv` and `rq2_coordination.csv` report the range actually seen.
Measured across 30 seeds of `realistic`, both devices land at **73–82% online (mean ~77%)** — a
direct consequence of `shortOfflinePeriodsPerDay` × `shortOfflinePeriodHours` (roughly 2 periods ×
3.5h ≈ 7 offline hours of a 24h day), not a separately-tuned target. This is reported as measured;
the parameters are not adjusted to chase a particular online-fraction figure.

**What this means for reading results:** every row in `stress` that differs from `realistic` exists
to put pressure on a rule (reversal, staleness, chain-gap buffering, de-duplication, budget
renewal under contention) — none of them is a claim about how often a real business actually sees
dropped connections or reordering. Business-shape fields (amounts, rates of sales/expenses,
settlement cadence) are identical between the two configs on purpose: `stress` is the same
business under worse conditions, not a different one.

## Run lengths

> **RQ1 results (2026-10-18, commit `13110e9`, 300 seeds/config, 90-day runs):** 600/600 runs
> passed every check — `liveConverged`, `backupConverged`, `identicalRecords`, `dashboardMatch`,
> `settlementStable`, `budgetSafe` and `noFalseAlarms` are `true` on every row of
> `rq1_correctness.csv`; `rq1_failures.csv` has no rows besides its header.
>
> `settlementStable` (spec 6.7's "a closed period never recalculates") was actually exercised on
> 297/300 `realistic` seeds and 293/300 `stress` seeds — the other 10 seeds had no closed
> settlement period to check against. A read-only diagnosis of all 10 (see
> `tool/diag_rq1_zero_settlement.dart`, not committed) found the same cause in each: within the
> 90-day window only two of the ~3 settlement opportunities fell due, and both of that seed's
> proposals happened, independently, to be rejected (`settlementRejectChance` = 0.10 per proposal,
> so two in a row is a roughly 1-in-100 event). None were left `waiting`/stuck — every proposal was
> answered. This is expected simulation behaviour, not a liveness defect.
>
> With zero failures, the rule of three bounds the true failure rate at roughly 3/300 ≈ 1% (95%
> confidence) for every check that ran on all 300 seeds, and at roughly 3/297 ≈ 1% (`realistic`) /
> 3/293 ≈ 1% (`stress`) for `settlementStable` specifically, based on the seeds it actually
> exercised.
>
> Total runtime: about 63 minutes of CPU time (matching the ~6.3 s/run measured earlier), though
> the background run's wall clock read 365 minutes — the machine slept partway through and the
> process resumed without dying, it did not hang. Machine: AMD Ryzen 7 PRO 4750U (8 cores / 16
> threads), 16 GB RAM, Dart SDK 3.10.7 (stable, windows_x64), Windows 11 Pro.
>
> **RQ2 results (2026-10-18, commit `7bf96c1`, 40 seeds/config, 3 months each):** 240/240
> (seed × month) rows in `rq2_coordination.csv` have at least one `consentProposals` and one
> `responses` record, so every coordination bucket was exercised throughout, not just on average.
> `partnershipCreateCount` is exactly 40 in both configs' summary rows (1 per seed, as the method
> requires) — a correctness sanity check on the classifier itself, not just the workload.
> `coordinationFreeShare` is 0.938 (`realistic`) / 0.938 (`stress`) and `consentProposalsShare` is
> 0.062 / 0.062 — most writes need no coordination at all, as the design intends.
> `expensesPerBudgetApproval` is 6.28 (`realistic`) / 7.23 (`stress`): one round of budget
> coordination covers several stand-alone expense writes. Total runtime: under 6 minutes (5 m 49 s
> wall clock, matching the ~4.3 s/run measured earlier — no sleep interruption this time). Machine:
> same as RQ1, above.
>
> **RQ4 results (2026-10-19, commit `f9b94ed`, 50 seeds/attack/config, 90-day runs):** 1,200/1,200
> attack attempts (12 attack types × 2 configs × 50 seeds) are in `rq4_security.csv`; every single
> one has `detected = true`, in both configs, for every attack type — 100% detection, no exceptions.
> The 9 "ordinary" attack types (`signatureTamper`, `outsideKey`, `wrongRole`, `forgedCreate`,
> `chainTamper`, `idConflict`, `nonCanonical`, `malformedSchema`, `overBudgetExpense`) are also
> clean on the second check: `noImpact = true` on all 50/50 seeds in both configs — the forged or
> malformed record is rejected and nothing else in the ledger is affected.
>
> The 3 equivocation-family attacks reconfirm, at full scale, the quarantine finding already
> documented below ("Quarantining an equivocator can undo the honest partner's own consent"):
> `equivocationAtBudgetApprove` has `honestUnaffected = 0/50` in both configs, and
> `equivocationAtSettlementCut` has `settledUnchanged = 0/50` in both configs — the honest partner's
> real approval or already-closed settlement is collaterally undone every single time the targeted
> seq is hit, not just occasionally. The untargeted, generic `equivocation` attack (which lands on a
> random seq, not deliberately on a consent-bearing one) shows the same effect only part of the
> time, as expected: `honestUnaffected` 19/50 (`realistic`) / 26/50 (`stress`), `settledUnchanged`
> 47/50 (`realistic`) / 48/50 (`stress`). These numbers replace the 15-seed smoke-test numbers in
> the table below.
>
> One seed was skipped and substituted: `stress` seed 43 has zero effective settlements in its
> 90-day window (the same deterministic workload already diagnosed above, for the identical
> reason — two settlement proposals, both independently rejected by chance), so
> `equivocationAtSettlementCut` requires at least one effective settlement to target and found
> none; the tool moved on to seed 51 to reach 50 usable seeds, exactly as its own comments describe
> (`_seedPoolSize = 400`, skipped seeds are not counted as a pass or fail). This is the same
> already-adjudicated cause as the RQ1 finding, not a new issue, and every other attack type still
> has all 50/50 seeds from the original 1–50 range for `stress`.
>
> With zero detection failures across 1,200 independent attempts, the rule of three bounds the true
> non-detection rate at roughly 3/1,200 ≈ 0.25% (95% confidence) overall, or about 3/50 = 6% within
> any single attack/config cell taken alone. Total runtime: about 17 minutes of actual compute
> (matching the ~4.25 s/run measured earlier, 1,200 runs), though the background run's wall clock
> read 668 minutes — the machine slept overnight partway through and the process resumed without
> dying, it did not hang. Machine: same as RQ1/RQ2, above.
>
> **RQ3 fixture generation (2026-10-19/20, commit `abf8759`, `realistic` config, seed 123):** the
> planned ladder was 1 month / 12 months / 10 years, landing near 100 / 1,000 / 10,000 records. The
> 10-year job did not finish: it was left running under a 6-hour internal cap, the cap never fired,
> and it was killed by hand after running 379m50s (about 6h20m) with no fixture written. Two
> fallback lengths were generated instead — 3 years and 5 years — and both finished:
>
> | Length | Days | Records/side | Generation time |
> |---|---|---|---|
> | 1 month | 30 | 65 | 1.3 s (1,302 ms) |
> | 12 months | 365 | 731 | 49.2 s (49,240 ms) |
> | 3 years | 1,095 | 2,268 | 91.2 min (5,470,518 ms) |
> | 5 years | 1,825 | 3,751 | 972.2 min / 16.2 h (58,332,592 ms) — see caveat below |
> | 10 years | 3,650 | — (never finished) | > 6h20m, killed manually |
>
> This growth is itself RQ3 evidence, independent of the benchmark below: going from 3 years to 5
> years is a 1.67× increase in days but a 10.7× increase in generation time, consistent with the
> full-ledger recalculation cost growing much faster than record count (see "Where the time goes").
>
> The 6-hour cap was supposed to stop the 10-year job automatically, and it did not. The mechanism
> (a `Timer` in a separate main isolate, racing a worker isolate that does the actual generation)
> was built specifically to avoid two already-diagnosed failure modes — an external `timeout`
> wrapper whose signal doesn't reach a native `dart.exe` child on Windows, and a same-isolate
> `Future.delayed` that a CPU-bound async function's own microtask chain can starve — and it passed
> its own smoke test. It still failed on the real, much longer run. The likely cause (not confirmed):
> a `Timer`, in any isolate, only fires when that isolate's event loop gets a turn between
> microtasks; if the generation loop's `await`s keep completing immediately rather than yielding to
> the event queue, the main isolate's own Timer can be starved the same way a same-isolate one was,
> just over a longer run before it becomes visible. A `Stopwatch` polled from inside the generation
> loop itself would not have this problem, since it needs no callback to fire at all. This is not
> fixed yet — the existing four-length ladder was accepted as sufficient for RQ3 rather than
> debugging the cap mechanism further.
>
> Caveat on the 5-year number: that run was partly on battery (the laptop's lid-close sleep setting
> was in effect overnight), and Windows' event log recorded several battery-saving transitions
> during the run, so CPU throttling may have inflated 972.2 minutes somewhat above what a
> continuously-plugged-in run would show. The 3-year number has no such caveat. Neither caveat
> changes the qualitative finding — generation time grows much faster than ledger size either way.
>
> **RQ3 benchmark (2026-10-20, `tool/benchmark_recalc.exe data/realistic_seed123_5years.json`):** run
> with the laptop on AC power (confirmed: `BatteryStatus=2`, 100% charge) and no other evaluation
> process running (confirmed: the only `dart.exe` processes present were long-lived VS Code/analysis
> server instances with negligible accumulated CPU, not an evaluation job). Results are in "Where
> the time goes" below. The 5-year fixture (3,751 records) is the largest available, so sizes 5,000
> and 10,000 from the tool's own list were not reached — only 100 / 1,000 / 2,500 were measured.

- **RQ1 (correctness of delta sync):** several hundred seeded runs per config, each covering about
  a month, so the sample is large enough to catch rare merge or ordering bugs rather than relying
  on a handful of lucky runs.
- **RQ3 (performance vs. ledger size):** originally planned as 1 month, 12 months and 10 years, to
  land close to 100, 1,000 and 10,000 total records. The 10-year generation did not finish within
  its time cap (see above), so the actual ladder used is 1 month / 12 months / 3 years / 5 years —
  still roughly two orders of magnitude of growth, just topping out at about 3,750 records instead
  of 10,000. The actual record counts reached are in the table below.

### Cached fixtures

A 10-year run takes real time to generate (see "Where the time goes" above), and RQ3 reads the
same ledgers repeatedly while measuring sync size and verification time. Regenerating them for
every measurement would waste that cost many times over, so each `(config, seed, days)` ledger is
generated once and cached as a file:

```
dart run tool/generate_fixtures.dart          # generate anything missing
dart run tool/generate_fixtures.dart --force  # regenerate everything
```

Fixture files live under `packages/evaluation/data/` (gitignored — they are large and reproducible
from the command above, so they do not belong in the repository). Each file holds the config name,
seed, both devices' final ledgers in full (every record, as `Record.toJson()`), and the generation
time in milliseconds, so later analysis can read a ledger back without re-running the simulation.

RQ3 only needs the `realistic` config's size ladder (it studies performance vs. size, not
coordination pressure). `stress` fixtures were skipped for this phase: RQ1 and RQ2's own tools
generate their runs directly and never read this cache, so a `stress` fixture here would not
actually be reused by anything.

| Config | Length (days) | Investor records | Manager records | Generation time |
|---|---|---|---|---|
| realistic | 30 (1 month) | 65 | 65 | 1.3 s |
| realistic | 365 (12 months) | 731 | 731 | 49.2 s |
| realistic | 1,095 (3 years) | 2,268 | 2,268 | 91.2 min |
| realistic | 1,825 (5 years) | 3,751 | 3,751 | 972.2 min (partly on battery — see "Run lengths") |
| realistic | 3,650 (10 years) | _never finished_ | _never finished_ | _killed after >6h20m_ |

See the RQ3 entries under "Run lengths" above for the full account, including why the 10-year run
did not finish and the caveat on the 5-year number.

## Where the time goes

A 10-year run is slow (minutes to hours, not seconds) to generate. Before accepting that cost,
it was measured rather than guessed, to tell apart two very different explanations: wasted harness
work (fixable) versus genuine core cost (a real finding, not something to hide).

The generator's own interleaved `Stopwatch` timings (summed across whichever hours did anything)
showed the cumulative time spent answering pending items growing much faster than the ledger size.
That total mixes two things together, though: how often `approvalsInbox` gets called, and how much
each call costs — and cumulative numbers overstate the growth of the second one, because both are
rising at once. Isolating the real question — **how does one call's cost grow with ledger size** —
needs each call timed on its own, not read off a running total.

`tool/benchmark_recalc.dart` does that: it takes size-100 / 1,000 / 2,500 / 5,000 / 10,000 prefixes
(in authorship order, so each prefix is a real run shape) of a cached `realistic` fixture, and times
`approvalsInbox`, `computeEffective` and `buildDashboard` in isolation — many repetitions per size
after a warm-up, reporting the median, as a compiled executable (`dart compile exe`) so Dart's JIT
warm-up doesn't add noise to the numbers.

**Results (2026-10-20, `data/realistic_seed123_5years.json`, laptop plugged in, nothing else
running):** the 10-year fixture never finished generating (see "Run lengths"), so this ran against
the largest fixture that did — 5 years, 3,751 records, added as the ladder's top point. The two
larger sizes on the tool's own list, 5,000 and 10,000, were not reached:

| Records | `approvalsInbox` (ms) | `computeEffective` (ms) | `buildDashboard` (ms) |
|---|---|---|---|
| 100 | 0.10 | 0.07 | 0.08 |
| 1,000 | 5.20 | 2.80 | 2.87 |
| 2,500 | 40.33 | 21.18 | 23.65 |
| 3,751 | 122.76 | 42.25 | 45.45 |

The growth is clearly super-linear throughout, and gets worse, not better, as the ledger grows: 100
→ 1,000 is a 10× increase in records but roughly a 52× (`approvalsInbox`), 40×
(`computeEffective`) or 36× (`buildDashboard`) increase in time; 1,000 → 2,500 (2.5× the records)
brings a further ~7.6–8.2× increase across all three; 2,500 → 3,751 (1.5× the records) brings a
further ~1.9–3.0× increase, with `approvalsInbox` growing noticeably faster than the other two at
this step. Every step is worse than the matching linear prediction, and several exceed even the
matching quadratic one (10× records should give ≤100× under quadratic, but these reach only
36–52×, so that step is actually sub-quadratic; 2.5× should give ≤6.25×, but these reach 7.6–8.2×,
exceeding it; 1.5× should give ≤2.25×, which `approvalsInbox` exceeds at 3.0× while the other two
stay just under it at ~1.9–2.0×) — so the curve is not a clean power law, but it is unambiguously
and consistently worse than linear at every step measured. This matches the fixture-generation
times above, which grow even faster still (3 years → 5 years was a 1.67× increase in days but a
10.7× increase in generation time) — the generator calls these same functions repeatedly while
simulating, so its own slowdown is a direct symptom of this cost. All three functions share the
same cause: `approvalsInbox` calls `decideApprovals` and `computeEffective`; `buildDashboard` calls
`computeEffective` and `computeMoney`; all rescan **every** usable record from scratch on every
call, by hard rule 5's design (deterministic, no stored derived state) — there is no incremental
version.

**What this means for the app, not just the generator:** `apps/mobile/lib/dashboard/dashboard_screen.dart`
calls both `approvalsInbox` (for its inbox-count badge) and `buildDashboard` fresh **on every widget
rebuild**, by design (so the numbers are always current — the same reason core has no stored derived
state). That is fine at the record counts Phase 7 was built and tested against; this measurement is
what tells us whether it stays fine as a real partnership's ledger grows over years.

**Conclusion:** the cost is genuine core recalculation — the same functions the app's own screens
call — not harness overhead, so it was measured and reported here rather than worked around. No
`qirad_core` change was made (Phase 8 is scope-frozen, and the app is not unusable at today's
realistic ledger sizes); incremental recalculation is tracked as future work in `docs/plan.md`.

## Sync payload size (full vs delta)

**Results (2026-10-20, `tool/rq3b_sync_size.dart data/realistic_seed123_5years.json`):** full-state
size (every record up to that point) versus one ordinary delta sync (median day's new records plus
the version vector — see RQ3b above for exactly what "ordinary" means here):

| Records | Full-state bytes | Delta records (median/day) | Delta bytes (median/day) | Version vector bytes | Full ÷ delta |
|---|---|---|---|---|---|
| 100 | 44,924 | 2 | 909 | 98 | 44.6× |
| 1,000 | 448,501 | 2 | 876 | 100 | 459.5× |
| 2,500 | 1,121,854 | 2 | 878 | 102 | 1,144.7× |
| 3,751 | 1,683,491 | 2 | 878 | 102 | 1,717.8× |

(5,000 and 10,000 were not reached — the fixture used, same as RQ3's, tops out at 3,751 records,
which is now the ladder's top point.)

A day's typical sync stays close to flat (2 new records, under 1 KB) regardless of how big the
ledger already is, while the full-state download grows linearly with it — so the full/delta ratio
grows linearly too, not super-linearly: ratio ÷ records is ~0.446, 0.460, 0.458 and 0.458 at the
four sizes above — effectively a constant, confirming the ratio is a straight line through the
origin, not a curve. (This is a different growth shape from recalculation *time* above, which is
super-linear — the two measure different things and should not be conflated.) This is the expected
shape for a delta protocol: a device that syncs regularly pays a near-constant cost per sync no
matter how old the partnership gets, and only a brand-new device (or one resyncing from scratch)
pays the full-state cost — which is exactly the gap this measurement was built to check, since
`docs/plan.md`'s Phase 8 checklist asks for it by name.

This measures payload **bytes**, not network time — no actual network call is made or timed here
(that would depend on the device's connection, which is a separate, unmeasured variable). It is also
a proxy, not a replay of real sync calls: the cached fixture only logs when each record was
authored, not when any sync happened or what it carried, so "one ordinary sync" stands in for "the
records authored in one simulated day" (see RQ3b's method above for the reasoning and its limits).

## What the generator actually does

One investor device and one manager device each hold their own `Validator`. The run ticks hour by
hour:

- Day 0: the investor creates the partnership and immediately logs the agreed starting capital.
  The investment is stored right away and becomes effective retroactively once the manager's
  approve arrives, matching how the app itself treats records that arrive before approval.
- Each device has its own precomputed online/offline schedule, and syncs through a shared in-memory
  relay (`RelaySim`) whenever it is online, using the same `syncOwnRecords` helper the real client's
  `SyncRunner._runOnce` shape is modelled on (query first, upload what is actually missing, repeat
  up to the spec's own repair-round limit). A record becomes a candidate for upload only once a
  sampled relay delay has elapsed since it was authored; occasionally a device's sync call is
  immediately repeated (to exercise de-duplication) or its received batch is shuffled before being
  fed to the validator (to exercise the chain-gap buffer, `stress` only).
- The run's final day is "quiet": both devices are forced online for the whole day, and nothing new
  is authored or answered during it, so that window is pure sync time rather than a window where a
  record authored in the run's literal last hour would have no later tick left to sync — see
  "Simulation simplifications" below.
- Sales and expenses are generated hourly from a Poisson-style daily rate; a small fraction of each
  are later reversed by the same author, after a delay, exactly like a real correction.
- Budget renewal, ratio changes and settlements are triggered by business conditions (budget
  running low, a periodic-with-jitter schedule) rather than a fixed simulation clock, and every
  proposal is checked with `proposalRefusal` first, so a refusal in the data is one core itself
  would produce.
- After a settlement becomes effective, each partner sometimes requests a profit withdrawal
  (`profitWithdrawalChance`), sized to a fraction of their now-settled, not-yet-withdrawn share.
- Separately, and rarely, the investor requests a capital withdrawal (`capitalWithdrawalDailyChance`)
  — a partial draw-down of the current cash balance, independent of any settlement.
- Every answerable item (partnership approval, budget, ratio, withdrawal, reversal, settlement) is
  answered through the same `answerEligibility` → `answerConsent` path `RecordWriter` uses, with a
  "shown" consent snapshot captured once, when the item first appears — so a later change before
  the scheduled answer can genuinely make it stale, exercising spec 6.7's staleness check for real.

See `packages/evaluation/lib/src/workload_generator.dart` for the implementation and
`packages/evaluation/test/workload_generator_test.dart` for what is verified about it
(determinism, convergence, and that every record type appears).

## Simulation simplifications

These are deliberate differences from the real client, called out here so a reader does not mistake
either one for a claim about the sync protocol itself:

- **Each device's sync call only offers its own unacknowledged records as upload candidates**, not
  every saved record the real client re-sends on every call (`apps/mobile/lib/sync/sync_runner.dart`
  re-sends everything "because a smaller candidate list would be only a bandwidth shortcut" — true
  here too). This is a pure bandwidth shortcut for the simulation: it never needs to recover another
  device's lost upload, since nothing in the generator ever drops a write before it reaches the
  relay. What counts as "unacknowledged" is read fresh from the relay's reply in the *current* sync
  round every time (`syncOwnRecords`, `packages/evaluation/lib/src/sync_through_relay.dart`), never
  from a remembered vector — the same rule spec 7.3 and `docs/decisions.md`'s "sync loop must not
  trust a cached relay vector" require of the real client.
- **The run's final day is quiet** (see "What the generator actually does" above): no new records
  are authored or answered while both devices sit in the forced final online window. Without this,
  a record authored in the simulation's literal last hour would have no later tick left in which
  either device could sync it, regardless of how well the protocol itself behaved — a finite-run
  boundary artifact that would otherwise show up as a `liveConverged` failure unrelated to sync
  correctness.

## Threats to validity

- **RQ1's `liveConverged` and `backupConverged` are two different checks, and a passing backup
  never hides a failing live check** (both are required for `passed`, and `rq1_failures.csv` logs
  `liveConverged` failures even when `backupConverged` passes). `liveConverged` compares the two
  devices' own validators exactly as the simulation left them, after a run that ends with a forced
  mutual-online, quiet window — the closest this harness gets to "did the live protocol actually
  converge," though it still only exercises the protocol while nothing new is being written in that
  final window. `backupConverged` (`_resyncThroughRelay`) separately takes the two devices'
  already-finished record sets and replays them through the real delta protocol (`RelaySim`,
  `firstMissingSeqs`, version vectors) from scratch, once, at the end — a cross-check with no time
  pressure or partial-eligibility behaviour of its own, not a stand-in for `liveConverged`.
- **`RelaySim` is a Dart mirror of the PHP relay's logic** (exact-text storage, hash de-duplication,
  gap-aware version vector), not the relay itself — it exists so RQ1 can run inside the pure-Dart
  evaluation package without a live server. The real PHP relay is covered separately by the CI
  month scenario (`relay/tests`), which runs the actual server code.
