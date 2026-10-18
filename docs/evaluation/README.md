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

**Method:** cached fixtures (`tool/generate_fixtures.dart`) at roughly 100 / 1,000 / 10,000 records
(about 1 month / 12 months / 10 years of `realistic`), read back as size-N prefixes in authorship
order; `tool/benchmark_recalc.dart` times each function in isolation, as a compiled binary (no JIT
warm-up noise), with a warm-up phase and enough repetitions that the median is a real element, not
an average.

**Metrics:** median milliseconds per call, for each of the three functions, at each size.

**Output:** fixtures cached under `packages/evaluation/data/` (gitignored, regenerable);
`benchmark_recalc.dart`'s printed table, recorded into this README's "Where the time goes" table.

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

> **Status: `rq1_correctness.csv`, `rq1_failures.csv`, `rq2_coordination.csv` and
> `rq2_coordination_summary.csv` are superseded.** They were generated from 30-day runs, and
> `settlementIntervalDays` (30) can never trigger within a 30-day run (the day-index loop only
> reaches day 29), so no run in either config has ever produced a settlement — every
> `settlementStable` check so far has passed vacuously, without ever exercising spec 6.7's "a
> closed period never recalculates" rule. RQ1's 300/300-pass, 0/300-non-trivial result above is
> real but uninformative about settlements for the same reason. Both tools are being changed to
> 90-day runs (about three settlement cycles) and re-run; this note is removed once that lands.

- **RQ1 (correctness of delta sync):** several hundred seeded runs per config, each covering about
  a month, so the sample is large enough to catch rare merge or ordering bugs rather than relying
  on a handful of lucky runs.
- **RQ3 (performance vs. ledger size):** three run lengths per config — about 1 month, 12 months
  and 10 years — chosen to land close to 100, 1,000 and 10,000 total records respectively, so
  performance is measured across roughly an order of magnitude at each step, not just at one size.
  The actual record counts reached (not just the target) are in the table below.

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
coordination pressure); `stress`'s two shorter lengths are cached too, for RQ1/RQ2 reuse.

| Config | Length (days) | Investor records | Manager records | Generation time |
|---|---|---|---|---|
| realistic | 30 | 68 | 69 | 2.1 s |
| realistic | 365 | 765 | 765 | 21.8 s |
| realistic | 3,650 | _pending — see below_ | _pending_ | _pending_ |
| stress | 30 | _pending_ | _pending_ | _pending_ |
| stress | 365 | _pending_ | _pending_ | _pending_ |

These rows were still generating in the background as this was written; the final numbers land
here once `tool/generate_fixtures.dart` finishes.

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
(in authorship order, so each prefix is a real run shape) of the cached 10-year `realistic` fixture,
and times `approvalsInbox`, `computeEffective` and `buildDashboard` in isolation — many repetitions
per size after a warm-up, reporting the median, as a compiled executable (`dart compile exe`) so
Dart's JIT warm-up doesn't add noise to the numbers. Results:

| Records | `approvalsInbox` (ms) | `computeEffective` (ms) | `buildDashboard` (ms) |
|---|---|---|---|
| 100 | _pending_ | _pending_ | _pending_ |
| 1,000 | _pending_ | _pending_ | _pending_ |
| 2,500 | _pending_ | _pending_ | _pending_ |
| 5,000 | _pending_ | _pending_ | _pending_ |
| 10,000 | _pending_ | _pending_ | _pending_ |

A rough read from the generator's own numbers before this isolated measurement existed: per-call
cost was around 28 ms near 1,400 records and around 72 ms near 2,450 records — growing faster than
the ledger size, somewhere between linear and quadratic, but not pinned down more precisely than
that without the table above. All three functions share the same cause: `approvalsInbox` calls
`decideApprovals` and `computeEffective`; `buildDashboard` calls `computeEffective` and
`computeMoney`; all rescan **every** usable record from scratch on every call, by hard rule 5's
design (deterministic, no stored derived state) — there is no incremental version.

**What this means for the app, not just the generator:** `apps/mobile/lib/dashboard/dashboard_screen.dart`
calls both `approvalsInbox` (for its inbox-count badge) and `buildDashboard` fresh **on every widget
rebuild**, by design (so the numbers are always current — the same reason core has no stored derived
state). That is fine at the record counts Phase 7 was built and tested against; this measurement is
what tells us whether it stays fine as a real partnership's ledger grows over years.

**Conclusion:** the cost is genuine core recalculation — the same functions the app's own screens
call — not harness overhead, so it was measured and reported here rather than worked around. No
`qirad_core` change was made (Phase 8 is scope-frozen, and the app is not unusable at today's
realistic ledger sizes); incremental recalculation is tracked as future work in `docs/plan.md`.

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
