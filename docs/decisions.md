# Decisions log

Record every decision that changes or clarifies the spec. One entry per decision, newest last.

Template:

```
## YYYY-MM-DD — short title

**Decision:** what was decided.

**Reason:** why.
```

---

## 2026-10-02 — First response wins, not reject wins

**Decision:** For every needs-approval record, only each partner's first `approve`/`reject`
(lowest `seq`) targeting it counts. Later responses from the same author to the same target are
kept as evidence but ignored in calculations, shown in the UI as "ignored: later response." To
change their mind, a partner must create a new proposal, not a new response. Replaces the earlier
"reject wins over approve" rule.

**Reason:** "Reject wins" let a late-arriving reject flip an already-active decision back to dead
(for example, a ratio change both partners had already relied on). Decisions must be monotonic:
pending → active or pending → dead, never backward. The first-response rule is deterministic across
devices because the hash-chain/pending-buffer rule (spec §6.1 step 4) already forces every device to
evaluate an author's records in the same `seq` order, regardless of network arrival order.

---

## 2026-10-02 — Sync loop must not trust a cached relay vector

**Decision:** The client sync loop (spec §7.3) no longer decides "sync is finished" based on a
locally remembered belief about what the relay holds. Every sync, the client checks the relay's
*freshly returned* vector against its own local vector, for every author it holds records for
(including the other partner's). If the relay is missing anything, the client uploads the gap
immediately, in another `sync` call, up to 3 attempts before falling back to normal retry/backoff.
Added a required test: wipe the relay's database, then sync — the relay must end up holding every
record that exists on either phone.

**Test:** `after the relay loses its data, the next sync from either phone refills it`
(`apps/mobile/test/sync_recovery_test.dart`). Correction (2026-10-03): this test did not exist when this
entry was first written. It was added in commit 09ab8d6, after an audit found the claim false.

**Reason:** The old rule ("upload records above the relay's *last known* vector") is a stale-cache
bug: if the relay loses data (e.g. a database restore), the client's memory of what the relay has
doesn't shrink to match, so the client never re-uploads the records the relay lost — they're gone
for good even though a perfect copy still exists on the phone. The relay has no CRDT logic of its
own to notice or repair this (hard rule: the relay never interprets records), so only a client that
re-verifies against the relay's live state, every sync, can catch and fix it.

---

## 2026-10-02 — Budget validity must be monotonic

**Decision:** Section 6.4's `used(B)` is no longer recomputed from the whole history, excluding
whatever happens to be reversed at calculation time. Instead, process a budget's expenses and their
reversals in `seq` order, keeping one running `used` total. An expense's valid/over-budget status is
decided once, from `used` as it stood at that expense's own `seq`, and never changes again. A
reversal of a valid expense frees its amount from `used`, but only for expenses that come **after**
the reversal's `seq` — it cannot reach back and change an earlier expense's already-decided status.
Required test: budget 10,000, expenses 4,000/3,000/5,000/2,000 then a reversal of the
second expense — the third expense (flagged over-budget before the reversal) must stay flagged
afterward, even though the reversal frees enough room that it would have fit.
(`packages/qirad_core/test/budgets_test.dart`: "the grantee's own reversal frees budget only from its seq onward".)

**Reason:** The old rule recalculated `used(B)` fresh every time, counting only currently
non-reversed expenses. That made a later reversal retroactively change an earlier expense's status —
flipping an already-relied-upon "valid" expense to "over budget," or an already-flagged expense back
to "valid." Same monotonicity problem as the earlier "first response wins" (Section 5) and sync
(Section 7.3) fixes: a decision both partners have already acted on must never be rewritten by
something that happens later.

---

## 2026-10-03 — Only four record types can be reversed in v1

**Decision:** A `reversal` may only cancel `invest`, `sale`, `expense` or `withdraw_request`. A
reversal whose target is any other type is **invalid**: it is flagged, shown in the UI, and has no
effect. Reversing an `approve` or `reject` is therefore invalid too. Other reversals whose target does
not yet exist (for example, one that arrived before its target) have no effect yet, but are not
flagged, because they may become valid when the target arrives.

**Reason:** Reversing `partnership_create` would destroy the partnership. Reversing an active
`ratio_proposal` would flip a decision backward, so a new proposal is used instead. Closing a
`budget_proposal` early raises a cross-author ordering question (which of the grantee's expenses still
count), so it is future work. Responses are final under first-response-wins (Section 5), so a partner
changes their mind by proposing again, not by reversing a response.

---

## 2026-10-03 — Budget events are ordered by the grantee's seq

**Decision:** Each budget event is placed at a `seq` from the grantee's chain. An expense sits at its own
`seq`. A reversal by the grantee sits at its own `seq`. A reversal by the other partner sits at the `seq`
of the grantee's `approve` that makes it effective.

**Reason:** `seq` is per author, so the investor's and manager's `seq` values cannot be compared. Only the
manager writes expenses, and the other partner's reversal needs the manager's approval, so every budget
event already has a `seq` in the manager's chain. Clock time and arrival order are not allowed (hard
rules 3 and 5). Forbidding investor reversals was rejected: it removes a valid correction path.

---

## 2026-10-03 — Profit remainder goes to the investor

**Decision:** A profit is split with integer division. The manager gets `result * managerPercent ~/ 100`, and the investor gets the rest, so any remainder in paisa goes to the investor. A loss is carried entirely by the investor, and the manager's share is 0.

**Reason:** Shares must add up to the result exactly, with no paisa lost or created (hard rule 1, integers only). The investor is the party who puts up the capital, so the rounding goes to them. This matches spec section 6.5.

---

## 2026-10-03 — One partnership per ledger

**Decision:** A ledger holds exactly one partnership, named by the `id` of its accepted `partnership_create`. A `partnership_create` is valid only if its `partnership` equals its own `id`. Any record whose `partnership` differs from the ledger's is rejected at membership (spec 6.1, step 3). So a second `partnership_create` is never stored. If the manager rejects a create, the investor makes a new create, which is a new partnership with its own ledger. The rejected one stays as history.

**Reason:** The spec says "the approved `partnership_create`" (singular). Two creates in one ledger would make the active ratio depend on a tie-break, and no partner could say which partnership they were in. Making the id rule a validation rule removes the problem at the source, so the active ratio needs no tie-break.

---

## 2026-10-03 — Chains and version vectors are per partnership

**Decision:** `seq` and `prevHash` belong to a (partnership, author) pair. Each partner's `seq` starts at 1 in each partnership. A device's version vector is kept per partnership.

**Reason:** Once a partnership can be rejected and replaced, the same two keys can start a second partnership. Counting `seq` across partnerships would make the new chain look like it has a gap, or would let records from the old one be replayed into it.

---

## 2026-10-03 — Canonical JSON sorts by code point

**Decision:** Object keys are sorted by Unicode code point (spec 4.1), not by UTF-16 code units, which is what Dart's `String.compareTo` does. The Dart encoder compares code points directly.

**Reason:** The two orders differ for characters above U+FFFF (an emoji sorts before U+FF5E in UTF-16 but after it by code point). If the phone and the relay disagreed, the same record would give different bytes and hashes on each. The spec already says code point, so the code now matches it. v1 keys are ASCII, so no record changes today. A test pins the order with a key above U+FFFF.

---

## 2026-10-03 — Records are accepted only in canonical form

**Decision:** A record arrives as text. It is accepted only if re-encoding its parsed form in canonical JSON gives the same bytes (spec 4.1, 6.1 step 1). Extra whitespace, wrong key order, duplicate keys and `[]` for `{}` are all refused. The phones apply this in `Validator.receiveText` (qirad_core). The relay applies it before storing (relay sync step, Phase 5 step 4). Unknown top-level keys, unknown `body` keys for a type, and unknown record types are also refused at step 1.

**Reason:** Parsers disagree about duplicate keys: one keeps the first value, one keeps the last, and some reject. Two devices could then accept the "same" record and sign or hash different meanings. Comparing bytes after a round trip removes every such case at one point, so the relay can store the exact string and every phone hashes the same bytes. Refusing unknown keys stops extra data from riding along unsigned or being dropped by some devices and kept by others.

---

## 2026-10-03 — Device registration needs proof of possession

**Decision:** Registering a device is two requests. `POST /devices/challenge` issues a single-use nonce for a
public key, valid for 5 minutes. `POST /devices` must then carry a signature by that key over
`"qiradsync-register-v1:" + nonce`. The nonce is deleted as soon as it is used, whether the attempt
succeeds or fails. Spec 7.2 has the full rule.

**Reason:** A public key is public. Without proof that the caller holds the private key, anyone who knows a
partner's key could register it and receive a token. That token could download the whole ledger, which is the
partners' private financial data. The signature proves possession. The prefix is domain separation, so a
signature made for registration can never be replayed as a record signature (spec 4.2), and the reverse.

---

## 2026-10-03 — Known limitation: the relay can read ledger contents

**Decision:** Records are stored by the relay as plain canonical JSON. The relay can read every amount, note
and receipt hash in them. Encrypting records end to end is future work and is not part of v1.

**Reason:** The relay only needs to store and forward records and check signatures, which needs no secret. The
relay operator (or anyone who gets its database) can still read the ledger. This is accepted for v1. It must be
stated to the partners and reviewed before any move to a hosted relay that third parties run.

**Note:** The design report is maintained separately by the developer, outside this repository. It is not created
in the repo. This decision log is the source of truth in the repo.

---

## 2026-10-03 — The manager may sync once the partnership exists

**Decision:** Both keys named in the accepted `partnership_create` may sync once the partnership exists, including
the manager before approving. Before the create is stored, only the investor's device may sync, and only to upload
a valid `partnership_create` (spec 7.2, point 2). The relay does not interpret approvals.

**Reason:** The relay stores records and cannot see approvals, so an approval-based rule could not be enforced on
the relay. Both keys are already fixed by the create, so the membership check is simple and the same on every phone.

---

## 2026-10-03 — Equivocation is kept by the relay and sent to both partners

**Decision:** A version that clashes with a stored record (same `author` and `seq`, different hash) is kept in a
separate append-only `conflicts` table. The stored record is never overwritten. Every sync response carries every
version the relay holds at each conflicted position, to both partners. Each phone runs its own equivocation check
(spec 6.1 step 5).

**Reason:** If a conflict were reported only to the device that uploaded it, the equivocating partner would be the
only one to see it, and the other partner could never find out. Sending the evidence to both lets each phone flag the
partner itself, without trusting the relay's judgement.

---

## 2026-10-03 — A batch is processed with the partnership_create first

**Decision:** In one sync request, the relay handles a `partnership_create` before the other records, whatever order
they were sent in. The other records are then stored in any order. Order by `seq` is the phone's job (spec 6.1).

**Reason:** A phone may send a batch in any order (for example, records that arrive later are sent first). If the relay
checked records in arrival order, a valid record would be refused just because the create came after it in the batch.
The result must not depend on the order of the batch.

---

## 2026-10-03 — The first-sync refusal message does not reveal the partnership

**Decision:** A device that may not sync gets `403` with the message "This device is not allowed to sync this
partnership. If you are creating it, upload a valid partnership_create signed by the investor." The same message is
used whether or not the partnership exists.

**Reason:** A different message for "does not exist" and "not a party" would tell an outsider which partnership ids
are in use. One neutral message gives no such information.

---

## 2026-10-03 — The phone keeps exact texts and rebuilds the ledger on start

**Decision:** The phone's local store keeps the exact text of every record the validator did not reject (accepted,
pending, chain-invalid, equivocating, duplicate). It does not keep a separate pending table: pending records are
rebuilt by replaying the saved texts through the validator on start. Rejected texts are never saved. The table
refuses UPDATE and DELETE with triggers, the same rule as the relay.

**Reason:** The signature covers exact bytes, so the text is the only trusted fact. A separate pending table would
be a second copy of the same facts, and it could disagree with the validator. Keeping equivocating versions lets
the flag survive a restart, the same way the relay keeps both versions.

---

## 2026-10-03 — Device registration is its own Phase 6 step; the token lives in secure storage

**Decision:** Device registration (spec 7.2: challenge, then signed registration) is a separate Phase 6 step.
The sync client receives the bearer token as an input. The token is stored in secure storage, not in SQLite.
On a `401` from the relay, the app re-registers once and retries the sync. A second `401` stops with a clear
error instead of looping.

**Reason:** The token is a credential, so it belongs next to the private key in secure storage. Registration
is its own concept (proof of key possession), and it should be taught and tested on its own. One automatic
re-registration recovers from an expired token, and the limit stops a broken relay from causing an endless loop.

---

## 2026-10-03 — One validator per partnership; partnerships are registered explicitly

**Decision:** A phone can hold several partnerships. The record store keeps one `Validator` per partnership id.
Each incoming text is routed by its own `partnership` field. The core validator keeps its one-partnership rule
unchanged. A partnership is added only by an explicit `addPartnership(id)` call, made when the user creates or
joins one (for example by scanning the partnership id). Text for a partnership id that is not registered on this
device is refused as `rejectedMembership` and never stored. `savedTexts(partnership)` and
`versionVector(partnership)` require the id.

**Reason:** Spec 7.1 expects one version vector per partnership on a device that holds several. Creating a
validator from incoming data would let a malicious relay create unlimited validators and storage (a denial of
service). Explicit registration means the user decides which partnerships exist on the phone.

---

## 2026-10-03 — A joining phone pins the partnership's keys before accepting a create

**Decision:** The join code carries the partnership id and the investor's public key. A phone accepts a
`partnership_create` only if its `author` and `body.investor` equal the pinned investor key, and `body.manager`
equals the pinned manager key. The manager's phone pins its own key as manager. A create that does not match is
rejected and not stored, even if it arrives first. The key exchange is: the manager shows a QR with their key, the
investor scans it and creates the partnership, then the investor shows a QR with the join code. Spec section 2.1.

**Reason:** The relay could send a forged `partnership_create`, signed with the attacker's own keys. Without a pin,
a joining phone would accept the first valid create it sees. The join code itself is not secret. The pin is what
protects the phone.

**Also decided:** "3 attempts" in spec 7.3 means 3 repair rounds per sync run. Network retries (step 6) start a new
run with their own 3 repair rounds, and the two counts are kept separate.

---

## 2026-10-03 — Sync retries only failures that may go away

**Decision:** The phone retries a sync run with backoff (1 s, 2 s, 4 s … capped at 30 s, at most 5 retries)
only for a network error, a call that times out, or a relay `5xx`. A `4xx` is never retried, except that a `401`
makes the phone register again and resend the batch, once. Every relay call has a timeout: 30 s for the whole call, 10 s to open the connection.
Spec 7.3 step 6 states this.

**Reason:** A `403` or `422` gives the same answer on every try, so retrying only wastes battery and time. A
silent relay must not hang the app (spec 7.3). Retrying is safe because sync is idempotent: the relay reports a
record it already holds as `already`, so a repeated run never stores anything twice.

---

## 2026-10-03 — Partners compare a safety code before a join is confirmed

**Decision:** Both phones compute the same safety code from both keys, in a fixed order (investor, then manager).
The partners compare it in person or on a call before the partnership is confirmed. The code stays visible in the
partnership settings. The exact computation is in spec section 2.1 (SHA-256 of a domain-separated text, first 16
bytes mod 10^24, shown as 6 groups of 4 digits). The pure function is in `qirad_core`; the screens come in Phase 7.

**Reason:** The join code is not signed, so a swapped code on the manager's phone would pin the wrong investor. The
pin would then refuse the real create. A safety code made from both keys is different for any swap, in either
direction, and the partners can check it without trusting the relay.

**Why 24 digits:** A short code (for example 6 digits) could be matched by searching for a key with the same code.
About 80 bits makes that search infeasible.

---

## 2026-10-04 — A partnership's pins and create are saved in one transaction

**Decision:** The investor's phone checks the `partnership_create` on a candidate validator that holds the new pins,
and saves the pins and the create together in one database transaction. A refused create rolls the transaction back.
The phone registers the partnership in memory only after the commit.

**Reason:** Pins saved before the create was checked could stay behind after a refusal, with no create to explain
them. An all-or-nothing save means a refused start leaves no partnership, no pins and no record. The tests reopen
the database to check what is on disk.

---

## 2026-10-04 — Each partner's share is 1 to 99 percent

**Decision:** A `ratio` in `partnership_create` or `ratio_proposal` must have each share as a whole number from 1 to 99.
The validator refuses 0 and 100 in its schema step (spec section 5). The app refuses them when the investor types them.

**Reason:** A Mudaraba is a profit-sharing partnership, so both parties must share in the profit. A 0 percent share
would be unpaid work or a loan, not a Mudaraba. The rule is in the validator, not only in the app, so a create from
another app is refused the same way.


---

## 2026-10-05 — Open issue: a ratio change re-splits profit already earned

**Status:** Open. Design decided on 2026-10-05 (see the settlement entries below). Fixed when the settlement step is built. The dashboard warns about it until then.

**Problem:** Spec section 6.6 says a new ratio applies from its `effectiveFrom` date. Profit earned before the change
should keep the old ratio. But `buildDashboard` splits the whole result by the ratio active on one date, so the
old profit is re-split at the new ratio.

**Example:** 200,000 is earned at 60/40 (manager 80,000). Then a 50/50 change takes effect. The dashboard shows the
manager 100,000 for the same 200,000. The contract says 80,000.

**Why dates cannot fix it:** Record times come from phone clocks, so they are never used to decide anything (hard
rule 3). A date on a ratio change says when it should start, but not which earned profit it covers.

**Direction (agreed 2026-10-05):** A `settlement` record that needs the other partner's approval.
When it is effective, it freezes the result up to that point in the ledger and splits that result at the ratio active
then. A new ratio applies only to results after a settlement. The change is anchored to a point of consent, not a date.

**Until then:** The dashboard shows a note whenever a ratio change has taken effect, saying the split uses the current
ratio and may not match the contract until settlement is built. A core test documents the current behaviour and is
marked as a known issue. It must be updated when settlement is built.

---

## 2026-10-05 — The active ratio is picked by record order, not by date

**Status:** Decided. Option 1 from the open question was chosen by the developer.

**Decision:** The active ratio is the last effective `ratio_proposal` in `(effectiveFrom, author, seq)` order.
If there is none, it is the ratio in the approved `partnership_create`. No clock is used. The `effectiveFrom`
date is a sort key and display text only. The dashboard shows the ratio as text, for example
`50/50 (agreed to start 2026-11-01)`.

**Reason:** The date chose the ratio, and the ratio sets the shares people act on. A phone with a wrong clock
would show a different split. That broke hard rule 3, which says clock time must not decide anything. The
"display label only" framing was wrong, because the date still changed the numbers.

**Consequence:** A ratio change with a future `effectiveFrom` applies to all the current result at once. It does
not wait for its date. This is the same kind of problem as the open settlement issue above, and it is recorded
there. Spec 6.6 is updated to match.

---

## 2026-10-05 — Settlement: only the manager proposes, and proposals are decided in order

**Status:** Decided. Built in a later step.

**Decision:** Only the manager authors a `settlement`. The investor approves or rejects it. Settlement proposals are
decided in order: the investor's response to S_k is valid only if the investor has already responded to every earlier
settlement, at a lower investor `seq`.

**Reason:** If both partners can propose, two proposals can be approved at the same time from the same starting point.
Each approval is a valid record, so a grow-only ledger cannot undo either one. Any later winner would change an
already settled period, which breaks monotonicity. One author gives one chain, and the ordering rule keeps the
responses in order.

**Limitation:** In the app, the investor cannot force a settlement. Documented in spec 6.7. Future work.

**Test that must exist:** The investor approves S_2 before S_1 → the response is invalid and flagged.

---

## 2026-10-05 — First valid response wins; invalid responses never count

**Status:** Decided by the developer on 2026-10-05. Built in step 4a.

**Decision:** The first response rule (spec 5) picks the lowest-seq response among the valid ones. An invalid
response (such as an early answer to S_2) is kept as evidence and never counts. A later valid answer to S_2 decides
it.

**Reason:** Without this, one early mistake would lock S_2 for ever. The validity of a response depends only on
records that are already fixed: the investor's chain below that response, and the manager's settlement chain
below the proposal, which has no gaps. So a response never changes from valid to invalid, or back, and the result
is the same in any arrival order.

**Malformed and investor-authored settlements:** neither takes part in the ordering rule. Only well-formed manager
proposals do (spec 6.7).

**Tests that exist:** `packages/qirad_core/test/settlement_test.dart`. An early invalid answer to S_2, then answers to
S_1 and S_2: the S_2 decision is the later valid answer. Replaying the same records in other orders gives the same
result. An investor-authored settlement does not block the investor's answers. A malformed settlement does not block
the next proposal.

---

## 2026-10-05 — Settlement: the cut is closed, dominating and not empty

**Status:** Decided. Built in a later step.

**Decision:** A settlement's cut must be closed under references and under approvals. It must dominate the previous
effective cut, and it must cover at least one new record. The manager's value in the cut must be lower than the
settlement's own `seq`. The settlement body stores no totals.

**Reason:** Without closure, an approval outside the cut could change a settled period later. Without domination, a
later cut could move backward. Empty settlements only add noise. Storing a total would break hard rule 4.

---

## 2026-10-05 — Ratio changes take effect at the next settlement

**Status:** Decided and confirmed by the developer on 2026-10-05. Built in a later step.

**Decision:** Period 1 uses the create ratio. Period k uses the last effective `ratio_proposal` approved inside the cut
of period k−1. If there is none, it uses the previous period's ratio. The open period uses the same rule with the last
cut. A change approved inside a period applies to the next period, not to the current one.

**Consequence:** Until a settlement is effective, an approved change does not apply to any result. The dashboard shows
the old ratio and a note that a change is waiting for settlement.

**Confirmed:** A change approved during period k applies from period k+1. Before the first effective settlement, an approved change applies to nothing, and the dashboard shows the old ratio with a note.
---

## 2026-10-05 — Losses are carried forward before any profit is shared

**Status:** Decided. Built in a later step.

**Decision:** Keep a deficit across periods. A loss is added to the deficit and the investor bears it. In a profitable
period, the deficit is covered first (capital is restored first). Only the rest is split at that period's ratio.

**Limitation (documented, future work):** Provisional profit distributions made before a later loss are not clawed
back. The app shows them as provisional.

---

## 2026-10-05 — Corrections after settlement: one rule, recalculate one period and book the difference later

**Status:** Decided. Built in a later step.

**Decision:** A reversal of a record in an earlier period recalculates only the period that contains the reversed
record, as if the reversal had been there. The difference is booked in the period where the reversal becomes effective.
The difference has two parts:

- **Share change:** the change in the period's distributable amount, split at that period's ratio. It cannot make a
  share negative beyond what that period gave, because the new distributable amount is never below zero.
- **Deficit change:** the change in the period's carried deficit, added to the current carried deficit.

Later settled periods are never recalculated. The adjustment is shown as a separate line, "correction from an earlier
period".

**Reason:** One rule covers every case, and no special case is needed for a loss period. Recalculating the whole ledger
would change settled periods, which breaks monotonicity.

**Limitation:** If an adjustment removes profit a partner already withdrew, the excess is shown as an amount owed back.
The app does not collect it.

**Tests that must exist:**

1. Profit period with a small correction: only that period's shares change.
2. Loss period: the deficit grows, and the manager's share stays zero.
3. Profit period that becomes a loss: its shares go to zero and a deficit appears.

---

---

## 2026-10-05 — Rounding is per period

**Status:** Decided. Built in a later step.

**Decision:** Each period is split on its own with `splitResult`. Summed shares can differ from one split of the whole
result by up to one paisa per period. This is deterministic.

---

## 2026-10-05 — Profit withdrawals are not capped in v1

**Status:** Decided.

**Decision:** Profit withdrawals are not capped by settled shares. The approval screen shows the ratio-change warning
and each partner's settled share for reference.

**Reason:** A cap needs settlement to exist first. The warning is the protection until then.

---

## 2026-10-05 — Closure covers references only, not decisions

**Status:** Decided. Built in step 4b.

**Decision:** Cut rule 3 (closed) checks only that every record inside the cut refers to a record inside the cut.
Approval decisions are not part of closure. An unanswered request inside a cut has no effect in that period. Its
approval counts in the period where the approval falls.

**Reason:** If decisions had to be inside the cut, one unanswered request could block every later settlement
forever (liveness).

---

## 2026-10-05 — Phone-holds-cut, final once held, chained rule, permanent invalidity

**Status:** Decided. Built in step 4b.

**Decision:**
- A cut is checked only when the phone holds every record it covers. Until then the settlement is waiting.
- Once the phone holds the whole cut, rules 1 to 5 give a final answer. A settlement that fails a check is
  permanently invalid.
- Settlements are decided in manager seq order. A waiting settlement blocks later ones. A rejected or
  permanently invalid settlement is done and does not block.

**Reason:** A failed check must never be retried later with different records, or the result would depend on
arrival order. A permanently invalid settlement must not block the next one forever.

**Note on the chained flip:** A cut that is approved but not held cannot happen in a normal ledger. The investor
approves only after the settlement exists, and the manager's cut only covers records written before that. So the
phone holds the cut when it holds the approval (chains have no gaps). The waiting state covers only a cut that names
records the phone has not received.

---

## 2026-10-05 — A settled period is a pure function of its cut

**Status:** Decided. Built in step 4b.

**Decision:** A settled period's view (result and budget statuses) is calculated only from the records inside its
cut. Later effects, such as a late budget consent, are booked as a difference in the period where they become
effective. No snapshot is stored.

**Reason:** A fixed set of records always gives the same view, so a settled period never changes and hard rule 4
(store facts, calculate the rest) holds.

---

## 2026-10-05 — Late budget consent is booked where the budget becomes effective

**Status:** Decided. Built in step 4b.

**Decision:** If the grantee approves a budget after a cut, the budget (and any expense under it) is counted in the
period where it becomes effective, using the adjustment difference rule.

**Reason:** It keeps the principle above. The settled view stays the same, and the money shows up once, in the
current period.

---

## 2026-10-05 — Approve rule: an approve must come after its cut

**Status:** Decided. Built in step 4b (follow-up).

**Decision:** An investor `approve` of a settlement is valid only if the cut's investor value is below the approve's
own `seq`. Otherwise the approve is invalid, kept as evidence, and never counts. A `reject` is not affected. A
settlement whose cut names records that do not exist waits until the investor rejects it. Rejected counts as done,
so later settlements continue.

**Reason:** Phones cannot tell, when they see a cut that names investor records 41 to 99, whether those records
do not exist or have not arrived yet. So the rule must not make a settlement invalid right away. Instead it makes
the approve impossible to count. Then "a valid approve means the cut is held" is a rule that holds even with a
malicious manager, not an honesty assumption. The investor always has a way out: reject.

**Consequence:** An approve of a settlement can never be inside that settlement's own cut, because its seq is above
the cut's investor value. Closure still checks approves like any other reference.

## 2026-10-05 — Profit withdrawals belong to their author; owed back vs withdrawn ahead

**Status:** Decided. To be built in step 4d.

**Decision:** A profit withdrawal is paid to the partner who records it (its author). Each partner's excess is split
into two labels that always add up to the excess:
- **Withdrawn ahead of settled profit:** the part of the excess that already existed before any correction. It
  comes from withdrawals made before settlement. It is neutral, not a debt.
- **Owed back:** the part of the excess caused by a correction that reduced an already-settled share (spec 6.7,
  point 5). This is the only case shown as money owed. The app does not collect it.

**Reason:** The spec does not tie a withdrawal to a partner, so the author is the simplest rule and needs no change
to the record format. Two labels are needed because a withdrawal made before settlement is normal. Calling it a debt
would mislead people.

**Consequence:** The split is computed, not stored (hard rule 4). With `W` = the partner's effective profit
withdrawals, `own` = their profit shares from each period's own result, and `settled` = their profit shares with
corrections applied: `excessBefore = max(0, W − own)`, `excessNow = max(0, W − settled)`, `owedBack =
max(0, excessNow − excessBefore)`, `aheadOfSettled = excessNow − owedBack`.

## 2026-10-05 — Owed back uses closed periods only

**Status:** Decided. To be built in step 4d.

**Decision:** The withdrawn, own and settled figures all come from the same set: the closed periods (those before
the last effective cut). A correction that becomes effective in the open period does not change owed back until
that period is settled. The open period is shown on the dashboard as provisional.

**Reason:** If own and settled came from different sets, the subtraction would mix provisional and final numbers.
Nothing provisional should ever create a debt.

**Consequence:** Owed back can appear late, only after the period that caused it is settled. This is accepted.
A withdrawal made before any settlement is "ahead" only after the period that contains it is closed.

## 2026-10-05 — Audit follow-ups: create rule, total withdrawn, investor silence

**Decision (create body):** The validator refuses a `partnership_create` whose ratio does not sum to 100, whose
shares are not 1 to 99, or whose two party keys are missing or equal. Ratio proposals keep the old rule, where a bad
sum only means "no ratio".

**Reason:** A create has no earlier ratio to fall back on. A bad create would leave every period without a ratio.

**Decision (period code):** `periodShares` returns no periods, instead of throwing, when the create's ratio is not
valid. This only matters for records that did not come through the validator.

**Decision (total profit withdrawn):** Two separate values. `totalProfitWithdrawn` is each partner's sum of all
effective profit withdrawals on the whole ledger. The owed back and ahead split is calculated from closed periods only.
The dashboard shows the total from the first withdrawal. Until the first settlement it is labelled "not yet compared to
settled profit" and no split is shown.

**Reason:** A total that waited for a settlement would show 0 for a partner who has already withdrawn money. The split
still needs closed periods, so provisional numbers never create a debt.

**Decision (investor silence):** Kept as a rule. A settlement waits for the investor's answer, and the rules use no
clock, so there is no timeout. An investor who never answers is a dispute, resolved outside the app. The approvals
inbox shows "Settlement S_k is waiting for the investor's answer." This is listed under the v1 limitations in spec 6.7.

**Reason:** A timeout would need a clock or a new rule, and the spec forbids clock time in decisions. Silence is the
same case as a manager who never proposes.

**Mutation check (2026-10-06), result for the rules that no test can fail:** Removing the cut-held check (`cutIsHeld`)
or the chained rule (`settlement_states.dart`) changes nothing in a ledger the validator stores. A valid investor
approve already means the investor's chain up to that approve is held. Chains have no gaps (spec 7.1), so the
manager's cut is held too. The chained rule is covered by the ordering rule, which already requires the investor to
answer every earlier proposal. These checks are kept as a defence, and no test can fail without a ledger the validator
would never store.

**Decision (write gate, 2026-10-06):** A phone writes its own record only when its own chain is complete. It must
have synced the partnership on this install, and the relay's vector for its key must not be higher than its own
highest saved seq. Otherwise the write is refused and the phone syncs first (spec 7.4, rule 2).

**Reason:** A phone with an empty or partly restored store would otherwise reuse a seq the relay already holds. Two
different records with one seq is a fork that the relay can never repair.

**Decision (valid answer, 2026-10-06):** "Already answered" means a valid response only. An invalid early answer
(spec 6.7 ordering rule) does not stop the investor from answering again. A second valid answer is refused.

**Reason:** An invalid answer never counts, so it must not block the correct one. This follows spec 5, where invalid
responses never decide anything.

**Decision (one device per key, 2026-10-06):** Version 1 supports one device per key. The private key is never
exported or copied. Supporting several devices per partner is future work with its own design.

**Reason:** A second device with the same key would write its own records with seqs the first device does not know.
That is the same fork risk as above, so the relay vector gate cannot protect it.

**Finding (waiting-for-records state, 2026-10-06):** The approvals inbox state "Waiting for records to sync" cannot
happen from a stored ledger. The validator buffers a settlement until its earlier seqs arrive. The branch is kept as
defence in depth and is tested with hand-built records, the same approach as M9 in the mutation check.

**Decision (the writer never creates a record it knows is invalid, 2026-10-08):** "Kept as evidence" (spec 6.1, 6.7)
describes what the validator does with a record it *received* from the other partner. It does not mean this app's own
writer may knowingly build one. Before signing an approve or reject of a settlement, `RecordWriter` re-runs the
settlement ordering rule with the candidate added, and refuses with `answerEarlierFirst` if the candidate would land
in `invalidResponses`. Nothing is written.

**Reason:** A device can always tell, before writing, whether its own answer would be invalid. Writing it anyway only
creates a record that is already known to decide nothing, and it is harder to recover from a mistake already on the
chain than to refuse to make it. The rule that an invalid early answer does not block a later valid one still holds —
it now covers a record that reached the ledger some other way (an older app version, a different client), proved
with a hand-built record in the test.

---

## 2026-10-09 — Schema step enforces every type's body shape and `refersTo` use (spec 6.1 step 1, spec section 5)

**Decision:** `parseRecordSchema` now checks, for every record type, exactly what spec section 5 says that type's
body must contain and what `refersTo` must be — not just the top-level field shapes it already checked. Added:

- `time` must be `YYYY-MM-DDTHH:MM:SSZ` and parse as a real date (`_isValidTime`). `sig` must be a 64-byte Ed25519
  signature in canonical base64url-no-padding, round-tripped the same way `isCanonicalPublicKey` already checks a
  public key (`_isValidSig`). `prevHash` is checked as 64 lowercase hex characters by regex, not just length.
- A new `_matchesTypeRules` switch, one case per type: `invest`/`sale` need a positive amount and no `refersTo`;
  `budget_proposal` needs a positive amount and a canonical grantee key; `expense` needs a `refersTo` that is a
  UUID v4, a positive amount, and an optional `receiptHash` that is 64 hex characters; `withdraw_request` needs a
  positive amount and `kind` of `capital` or `profit`; `ratio_proposal` needs a valid 1–99 ratio whose shares sum
  to 100, and an ISO date `effectiveFrom`; `reversal`/`approve`/`reject` need a `refersTo` UUID v4 and an empty body;
  `settlement` needs no `refersTo` and a `cut` that is a `Map` (the deeper shape of `cut` stays a business-layer
  check in `settlementCut`, since it needs the partnership's two keys, which schema parsing does not have). A type
  with no case is refused by default, not silently accepted.
- `partnership_create`'s body check (`_isValidCreateBody`) now also requires `currency == 'PKR'` and that `investor`
  and `manager` are each a canonical public key (not just "a String, and the two differ").
- Removed the old sum asymmetry: a `ratio_proposal` whose shares don't sum to 100 is now refused at the schema step,
  the same as a bad `partnership_create` ratio, instead of being silently stored and only later ignored by `ratioOf`.

**Reason:** Before this, a `withdraw_request` with no `amount` or `kind`, a `settlement` with a `refersTo`, or an
`expense` with a non-UUID `refersTo` were all accepted and stored, because the schema step only checked that body
keys were a subset of the type's allowed keys — not that the required ones were present and well-formed. Business-
layer code (the inbox, the consent screens) then had to treat "missing/malformed required field" as a reachable
runtime state, which is the wrong layer: spec 6.1 step 1 is specifically the step that checks "every field a type
needs, with the right shape," before any business rule runs.

**Consequence found while verifying this:** the withdrawal screen's "no numbers to show yet" (missing-summary)
state is no longer reachable through the inbox in ordinary use, because every `withdraw_request` the schema now
accepts already has a valid `amount` and `kind`. Its test was kept as a labelled defensive test, built by hand with
`Ledger.add` bypassing `receive()` on purpose, per the "redundant protections are fine, untested ones are not"
principle already used for M9/M10 (see the 2026-10-06 mutation-check entry above). The equivalent settlement-screen
state, by contrast, turned out to still be real: see the next entry.

**Tests:** `packages/qirad_core/test/validator_schema_table_test.dart` (one table-driven test per type/field rule
above), plus updates to `record_schema_test.dart`, `active_ratio_test.dart`, `money_test.dart`, `settlement_test.dart`,
`budgets_test.dart`. `apps/mobile/test/withdrawal_confirm_screen_test.dart`'s defensive fixture.

**Known limitation, not fixed:** `_isValidTime` accepts some calendar-invalid-looking strings as valid whenever
`DateTime.tryParse` normalizes them (for example a day-of-month rollover). `time` is display-only (hard rule 3), so
this cannot affect any calculation; documented here rather than guarded against, to avoid adding code whose only
job is to reject a display string more strictly than Dart's own date parser does.

---

## 2026-10-09 — A settlement with an all-zero cut is a real reachable state, not a defensive-only one

**Finding:** While restoring the settlement screen's missing-summary test in the same defensive form as the
withdrawal one above, checking first showed this state is *not* defensive-only for settlements. `approvalsInbox`'s
settlement block (`_settlementBlock`) checks the cut's shape, that any earlier settlement is already answered, the
investor-approve seq bound, and `cutIsHeld` — it does not call `cutProblem`, which is where cut rules 3–5 (closed,
dominating, **not empty**) live (spec 6.7). So the manager's very first settlement, proposing a cut of
`{investor: 0, manager: 0}`, is a genuine, schema-valid, `receive()`-accepted record that reaches the inbox as
`canApprove: true, blockedReason: null` — the same as an ordinary settlement — yet never becomes
`SettlementState.effective` (`cutProblem` flags it as empty), so `settlementConsent` returns `null` and the
confirm screen has no numbers to show.

**Decision:** The settlement screen's missing-summary test uses this real empty-cut scenario, built the normal way
through `receive()`, rather than a hand-built bypass. It is still labelled and still guards the same rule (the
Approve button is never shown without numbers, for informed consent) as the withdrawal screen's defensive test, so
the two screens stay consistently tested — but this one needs no `Ledger.add` trick, because the state is reachable
in the real app.

**Reason:** Using the real scenario is a strictly better test than a hand-built one where a real example exists:
it proves the screen's guard against an input the validator genuinely accepts, not only against one invented for
the test. No code change was made to `_settlementBlock` itself (it is not wrong — it just doesn't duplicate a check
`cutProblem` already makes one layer in); flagged here as an optional future improvement, not acted on, since the
screen already refuses to show Approve without numbers either way.

**Test:** `apps/mobile/test/settlement_confirm_screen_test.dart`, `'no Approve when the settlement cut is empty'`.

**Superseded below (same day):** this entry's last paragraph called `_settlementBlock` not duplicating `cutProblem`
"not wrong." On review, the disagreement it causes — the inbox says approvable, the rules say the settlement can
never become effective — is a bug, not an accepted gap. See "approvalsInbox now reuses cutProblem" below, which
fixes it; that entry's fixture replaces this one's.

---

## 2026-10-09 — A cancelled request tells the other partner it was cancelled, not that it was "already answered"

**Decision:** The withdrawal confirm screen now tells the two "this request is gone from the inbox" cases apart.
If the request was reversed by its own author before being answered (spec section 5: a partner may reverse their
own pending record at any time, with no approval needed) the screen says "This request was cancelled by the
requester." Otherwise (a real approve/reject already decided it) it still says "This was already answered."
`approvalsInbox` already stopped listing a cancelled request (a 2026-10-08 fix to `approvals_inbox.dart`, using
`computeEffective(...).cancelledIds`); this is the matching screen-level message for the same case.

**Reason:** "Already answered" is misleading when nobody answered — the other partner would wrongly think a
decision was made, when the request was simply withdrawn before anyone had the chance to look at it.

**Test:** `apps/mobile/test/withdrawal_confirm_screen_test.dart`,
`'a request the requester cancelled says so, not "already answered"'`.

---

## 2026-10-09 — `approvalsInbox` now reuses `cutProblem`; the all-zero cut was a real bug

**Finding:** The previous entry's conclusion was wrong. `approvalsInbox`'s settlement block
(`_settlementBlock`) checked the cut's shape, that any earlier settlement was already answered, the investor-
approve seq bound, and `cutIsHeld` — but never `cutProblem`, which is where cut rules 3-5 (closed, dominating,
**not empty**, spec 6.7) live. That is not a harmless gap: it means the inbox and the effectiveness rules could
disagree. A settlement that can never become effective (an empty cut, one that moves backward, or one that
refers outside itself) was shown to the investor as an ordinary, approvable item, with nothing to tell them
Approve would do nothing.

**Decision:** `_settlementBlock` gained a fourth check, after `cutIsHeld`: it computes the cut before this
proposal (the last *effective* one, or `{0, 0}` if none yet — the same starting point `settlementStatuses`
tracks) and calls `cutProblem(records, parties, cut, previous)` — the exact function `settlementStatuses` already
calls once a settlement is approved, not a reimplementation of its rules. A non-null result blocks approve with a
plain-English reason, Reject highlighted, one message per rule:

- *covers nothing new* → "This settlement covers nothing new. Reject it."
- *does not cover the previous cut* → "This settlement moves the cut backward. Reject it."
- *refers to a record outside the cut* → "This settlement refers to a record outside its own cut. Reject it."

Reusing `cutProblem` instead of writing a second check means the inbox can never disagree with what
`settlementStatuses` decides later — one function owns cut rules 3-5, called from both places.

**A further finding, while restoring the settlement screen's defensive test:** unlike the withdrawal screen's
missing-summary test, there is no way to rebuild the equivalent "approvable but nothing to show" settlement state
by hand (`Ledger.add`, bypassing `receive()`). The only remaining path to `settlementConsent` returning `null` on
an otherwise-clean cut is a `partnership_create` with a ratio that does not sum to 100 (`periods.dart`'s decision
Q3b short-circuit) — but `Validator._partnershipKeys` (which the screen needs just to open) is set only inside
`receive()`'s success branch, right after the create passes the ratio-sum schema check. A bad-ratio create and a
populated `partnershipKeys` can never exist on the same validator, through any public call. So, for settlements,
this fix closes the gap completely — not only in ordinary use (true before this fix too) but by hand as well.

**Decision (test strategy, three parts):**
1. `packages/qirad_core/test/approvals_inbox_test.dart` — three new tests, one per `cutProblem` rule (empty,
   backward, outside-cut), each expecting its message and `canApprove: false`.
2. The settlement screen's missing-summary test is **not** restored as a widget-level fixture (there is none to
   build). Instead, `packages/qirad_core/test/period_safety_test.dart` gained a `settlementConsent`-level test:
   a hand-built bad-ratio create plus an otherwise ordinary settlement and preview approve still comes back
   `null`, not a crash — proving the function itself stays safe, even though no widget test can reach it. Same
   principle as M9/M10 (2026-10-06 mutation check): a redundant guard stays tested even when unreachable.
3. The Approve-button decision itself (`!blocked && !needsSync && summary != null`) was duplicated, slightly
   differently, in both confirm screens. Pulled out into one pure function, `canShowApprove` (new file
   `apps/mobile/lib/inbox/approve_gate.dart`), used by both: `summary == null`, or any non-null `blockedReason`,
   or `needsSync` — each alone hides Approve (deny-by-default, same spirit as `cutProblem` reuse). Both screens
   now call it instead of repeating the condition. Unit-tested directly in
   `apps/mobile/test/approve_gate_test.dart` (null summary, blocked reason, needs sync, all clear).
4. `emptyCutSettlementReady()`'s test in `apps/mobile/test/settlement_confirm_screen_test.dart` is updated to
   match: the all-zero cut is now blocked in the inbox itself ("This settlement covers nothing new. Reject it."),
   with Reject highlighted (`FilledButton`), not a plain `OutlinedButton` with "No numbers to show yet."

**Reason:** The spec's informed-consent rule (6.7) means Approve must never be offered for a settlement that can
never do anything. Discovering this only after the fact (the settlement goes `invalid`, silently, once answered)
is worse than refusing it up front, the same framing already used for the other three `_settlementBlock` checks.

**Tests:** `packages/qirad_core/test/approvals_inbox_test.dart`, `packages/qirad_core/test/period_safety_test.dart`,
`apps/mobile/test/approve_gate_test.dart`, `apps/mobile/test/settlement_confirm_screen_test.dart`.
