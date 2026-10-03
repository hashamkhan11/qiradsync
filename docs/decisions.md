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
Added the required test: budget 10,000, expenses 4,000/3,000/5,000/2,000 then a reversal of the
second expense — the third expense (flagged over-budget before the reversal) must stay flagged
afterward, even though the reversal frees enough room that it would have fit.

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
