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
