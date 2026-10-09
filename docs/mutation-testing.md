# Mutation testing of the settlement rules (spec 6.7)

**Purpose.** A passing test suite only proves something if the tests would fail
when the rules are broken. For each rule in spec section 6.7, one rule was
removed or changed at a time, and the test suite was run to see whether a test
failed. A test that catches the change "kills" the mutant.

**Method.**
- The code was copied to a scratch folder outside the repository. The scratch
  copy was deleted afterwards.
- Each mutant was one text replacement in `packages/qirad_core/lib/src/`.
- After each replacement, `dart test` was run. A mutant is **killed** when at
  least one test fails that is not a known copy-only failure.
- Known copy-only failures: `fixtures_test.dart` and `relay_fixture_test.dart`
  need files outside `packages/qirad_core`. They fail on an unmodified copy too,
  so they are not counted.
- Mutants M1 to M17 were run before the step 4 fixes. M12 was the only gap, and
  it was closed by `92fd915`. The settlement rule code has not changed since
  those runs. M9 and M10 were run again after the unit tests were added.

## Results

| # | Rule | What was changed | Result | Test that catches it (or reason) |
|---|---|---|---|---|
| M1 | Rule 1: only the manager writes a settlement | Investor-authored settlement allowed | Killed | `settlement_test`: "an investor-authored settlement is never effective" |
| M2 | Rule 2: no `refersTo` | Settlement with `refersTo` allowed | Killed | `settlement_test`: "a malformed settlement with a refersTo does not block the next proposal" |
| M3 | Rule 4: manager value below the settlement's own seq | Check removed | Killed | `settlement_test`: "a malformed cut is never effective" |
| M4 | Rule 3: values zero or more | Negative values allowed | Killed | `settlement_test`: "a malformed cut is never effective" |
| M5 | Cut rule: closed | Closed check removed | Killed | `settlement_test`: "an approved S1 that is not closed becomes permanently invalid" |
| M6 | Cut rule: dominating | Dominating check removed | Killed | `settlement_test`: "a cut that does not cover the previous cut is invalid" |
| M7 | Cut rule: not empty | Not-empty check removed | Killed | `settlement_test`: "an empty cut is invalid and does not block the next one" |
| M8 | Approve rule | Approve whose cut names future records is allowed | Killed | `settlement_test`: "an approve whose cut value equals its own seq is invalid", and "an approve whose cut names investor records that do not exist is invalid" |
| M9 | Cut held check | `cutIsHeld` guard removed in `settlementStatuses` | Killed | `settlement_rules_unit_test`: "an active settlement whose cut is not held stays waiting" (hand-built state, see note below) |
| M10 | Chained rule | `!blocked` removed in `settlementStatuses` | Killed | `settlement_rules_unit_test`: "a pending S1 keeps a later active S2 waiting" (hand-built state, see note below) |
| M11 | Ordering rule | Investor answer rule removed | Killed | `settlement_test`: "approving S2 before S1 is invalid" |
| M12 | Loss carry-forward | Cover changed in `_distribute` | Killed after a fix | Found a gap. `loss_carry_forward_test`: "a profit in a later period covers the earlier loss before anything is shared" was added. |
| M13 | Closed-period filter | Withdrawal split uses open periods too | Killed | `total_withdrawn_test` and `withdrawal_split_test`: "open period" |
| M14 | Correction clamp | Clamp at zero removed | Killed | `withdrawal_split_test`: "a correction that increases a share gives owed back 0" |
| M15 | Corrections | Corrections made cumulative | Killed | `periods_test`: "several corrections to one period" |
| M16 | Create validation | Ratio and party-key checks removed | Killed | `partnership_create_body_test` and `active_ratio_test` |
| M17 | `excessNow` formula | Formula changed | Killed | `settlement_property_test` and `withdrawal_split_test`: "open period" |

## Equivalent mutants

No mutant is left equivalent. M9 and M10 were first recorded as
**equivalent**: at system level no test can fail, because the approve rule (M8)
prevents the states they check. They are now killed by unit tests that build the
state directly.

**Why the system cannot reach these states.**
- **M9 (cut held).** A valid investor approve at investor seq `k` can only be
  held when the investor's chain up to `k` is held. The approve rule keeps the cut
  below `k`. Chains have no gaps (spec 7.1), so the manager's part of the cut is
  also held, because the settlement itself is held.
- **M10 (chained rule).** A valid approve of S2 needs the investor to have
  answered every earlier valid proposal first (ordering rule, M11). So when S2 is
  active, S1 is already decided and cannot be `waiting`.

**Why both checks are kept.** Each check is cheap, and it protects the result if
a later change to the approve rule or the ordering rule weakens one of them. This
is defence in depth. The unit tests prove that each check works on its own.

## Notes on the unit tests

- The chained rule has no separate function. It is the `blocked` flag inside
  `settlementStatuses` (`packages/qirad_core/lib/src/settlement_states.dart`).
  The tests call that function with hand-built records and hand-built decisions,
  so the state that the system cannot produce can still be checked.
- `cutIsHeld` has direct unit tests with hand-built records: a zero cut needs
  nothing, a missing seq is not held, and a record from the other partner does
  not count.
- The unit tests use unsigned records. This is allowed only because
  `cutIsHeld` and `settlementStatuses` never check signatures. Signature checks
  are tested elsewhere.

## Spec section 5: the partnership-activation gate (2026-10-09)

**Purpose.** Same method, a different rule: until `partnership_create` is
active, nothing else is effective (`effective.dart`) and nothing else can be
written (`record_writer.dart`). Two separate mutants, one per gate, run
directly in the working tree (edit, run the full suite, revert) rather than a
scratch copy, since each change was one line and immediately reverted.

| # | Rule | What was changed | Result | Tests that catch it (or reason) |
|---|---|---|---|---|
| M18 | `effective.dart`'s `partnershipActive` check | `(record.type == 'partnership_create' \|\| partnershipActive)` changed to always `true` | Killed, weakly | Before this entry's new tests existed, only 1 of 266 `qirad_core` tests caught it (`dashboard_test`: "an unapproved create gives no money, no ratio and no shares") and 0 of 137 mobile tests caught it. Four tests were added to close this: `effective_test.dart`'s new "partnership activation (spec section 5)" group (three tests — before approval nothing but the create is effective; a rejected create blocks the create itself and everything after; a record written before approval takes effect once approved, with no rewrite) and `approvals_inbox_test.dart`'s "before approval, only the create waits in the inbox...". With those added, the same mutation is caught by 5 tests. |
| M19 | `record_writer.dart`'s `partnershipNotActive` refusal | Condition changed to `current.target.type != 'partnership_create' && false` | Killed | `record_writer_test.dart`: "answering anything but the create is refused while it is still pending" — the only test in the mobile suite that exercises this refusal directly. No other mobile test happened to need it, which is expected: the gate is a single `if` with one well-named test, not spread across call sites the way the effectiveness check is. |

**Finding from M18.** The effectiveness gate was live in the code (committed
`771ae81`) with almost no test actually depending on it — every mobile
fixture that needed an active partnership already wrote the manager's
approve for unrelated reasons (to get a real settlement, ratio, etc.), so
removing the gate changed nothing those fixtures checked. Only one core test
happened to assert a value (`dashboard.money.capital`) that the gate
protects. This is the same shape of gap the rest of this file's table was
built to catch for the settlement rules; it took running the mutant to see it
for this rule too, since "the code is there" and "a test depends on the code
being there" are different claims.

## Weak spots left

- The mutants were run one at a time. Two broken rules at once were not tested.
- The scratch copies used for the M1-M17 runs are deleted. The method above
  lists the steps so the run can be repeated. M18 and M19 were run in place
  (edit, test, revert) and are reproducible the same way, directly on
  `packages/qirad_core/lib/src/effective.dart` and
  `apps/mobile/lib/storage/record_writer.dart`.
