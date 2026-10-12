# Evaluation workload generator

Phase 8 needs real numbers, not guesses: sync size, coordination cost, verification time, all
measured against runs that look like an actual two-partner Mudaraba business, not a toy. The
`packages/evaluation` package builds those runs by driving `qirad_core`'s real rules — the same
`buildRecord`, `signRecord`, `proposalRefusal`, `answerEligibility` and `answerConsent` the app
calls — through a seeded, hourly-tick simulation of one investor and one manager phone.

Every run is reproducible from `(config, seed)` alone: one `Random(seed)` drives every sampled
amount, delay and decision, and nothing in the generator reads the system clock (hard rule 3 —
simulated `time` fields are built from the tick counter, never `DateTime.now()`).

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
| `offlinePeriodsPerDay` | 1–3 | 1–2 | A phone goes offline a few short times a day under normal use. |
| `offlinePeriodHours` | 1–6h | 24–72h | **Models reality** at 1–6h: a work gap or overnight. **Stress** stretches this to 1–3 days specifically to force long divergence before sync. |
| `relayDelaySeconds` | 0–30s | 0–300s | **Models reality** at a normal connection's delay. **Stress** models a poor connection. |
| `duplicateRate` | 2% | 10% | Fraction of deliveries arriving twice (a retried sync re-sending records the relay already has), to exercise de-duplication. **Stress** raises this to test it harder, not because real syncs duplicate this often. |
| `reorderChance` | 2% | 15% | Extra chance a delivery is held back past its normal time, so records arrive out of `seq` order and exercise the chain-gap buffer. **Stress** raises this to test the buffer harder, not as a realistic rate. |

**What this means for reading results:** every row in `stress` that differs from `realistic` exists
to put pressure on a rule (reversal, staleness, chain-gap buffering, de-duplication, budget
renewal under contention) — none of them is a claim about how often a real business actually sees
dropped connections or reordering. Business-shape fields (amounts, rates of sales/expenses,
settlement cadence) are identical between the two configs on purpose: `stress` is the same
business under worse conditions, not a different one.

**A consequence worth knowing about:** under `stress`, the manager's daily budget-renewal attempt
(`budgetRenewalThreshold`) combined with the investor's 24–72h `answerDelayHours` means the budget
proposal can starve completely — a fresh proposal supersedes yesterday's before the investor's
delayed answer catches up, every day, for the whole run. In RQ2's 40 stress seeds this happened in
every non-degenerate run: zero effective budget approvals, hence zero expenses, for the whole
month. This is a real property of stress's parameter combination (poor connectivity can fully
block a consent-gated operation while coordination-free ones keep flowing), not a measurement
error — see `docs/evaluation/rq2_coordination_summary.csv`'s `expensesPerBudgetApproval` column.

## Run lengths

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
- Each device has its own precomputed online/offline schedule; a record pushed while its author is
  online is delayed by a sampled relay time, occasionally held back further (to force reordering)
  or duplicated, and only "arrives" once the recipient is next online.
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

## Threats to validity

- **RQ1 checks convergence after re-syncing each run's final state**, not syncs interleaved with
  ongoing writes: `_resyncThroughRelay` takes the two devices' already-finished record sets and
  replays them through the real delta protocol (`RelaySim`, `firstMissingSeqs`, version vectors)
  once, at the end. A device syncing mid-run, while still producing new records, exercises the
  same primitives but was not separately tested here.
- **`RelaySim` is a Dart mirror of the PHP relay's logic** (exact-text storage, hash de-duplication,
  gap-aware version vector), not the relay itself — it exists so RQ1 can run inside the pure-Dart
  evaluation package without a live server. The real PHP relay is covered separately by the CI
  month scenario (`relay/tests`), which runs the actual server code.
