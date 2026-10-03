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
