# QiradSync v1 — Technical Specification

This document is the contract for the code. If code and spec disagree, the spec is right, or the spec
must be changed first (and the change recorded in `docs/decisions.md`).

Scope of v1: **exactly two partners**, one `investor` and one `manager`, one partnership per ledger.

---

## 1. Core idea

The ledger is a **G-Set of signed records** (grow-only set). Merging two ledgers is set **union** by
record `id`. Every value shown to the user (balance, profit, ratio, budget left) is **calculated** from
the set of valid records by deterministic rules (Section 6).

---

## 2. Identity and keys

- Each device creates an **Ed25519** key pair on first launch. The private key never leaves the device
  (store it in secure storage).
- A partner is identified by their **public key**, encoded as base64url without padding (43 characters).
  This string is used in the `author` field and anywhere a partner is referenced.

### 2.1 Joining a partnership (pinned keys)

A phone must know the partnership's two keys before it accepts a `partnership_create`. Otherwise a relay could
send a forged create, signed with the attacker's own keys, and the phone would accept it first.

The keys come from a **join code**: the partnership id and the investor's public key. The join code is not
secret. The protection is the pin: the phone checks every create against the keys it pinned.

Key exchange (in the app):

1. The manager's phone shows a QR code with the manager's public key.
2. The investor scans it and creates the partnership, naming that key as `manager`.
3. The investor's phone shows a QR code with the join code (partnership id and investor public key).
4. The manager's phone scans the join code. It pins the investor key, and pins its own public key as the manager key.

**Rule:** a phone accepts a `partnership_create` only if its `author` and `body.investor` equal the pinned
investor key, and `body.manager` equals the pinned manager key. Any other create is rejected and not stored,
even if it arrives first. The real create is still accepted after a forged one was refused.

**Safety code.** The pin stops a forged create on the phone that holds it. It does not stop a swapped join code
on the manager's phone before the pin is set. To catch that, both partners compare a safety code:

1. Build the text `qiradsync-safety-v1:` + investor key + `:` + manager key, in UTF-8. Both keys are the
   canonical base64url text. The order is always investor first, then manager, on both phones.
2. Take SHA-256 of that text. Read its first 16 bytes as one big-endian unsigned integer, and take it
   modulo 10^24.
3. Write the result as 24 digits with leading zeros, in 6 groups of 4 separated by spaces.

The partners compare the code in person or on a voice call before the partnership is confirmed. A swapped key in
either direction gives a different code. The code stays visible in the partnership settings so it can be checked
again later. The screens are Phase 7; the function is in `qirad_core` (`safetyCode`).

---

## 3. Record format

Every record is a JSON object with these fields:

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `v` | int | yes | Format version. Always `1` in v1. |
| `id` | string | yes | UUID v4, lowercase. Unique per record. |
| `partnership` | string | yes | The `id` of the `partnership_create` record. For that record itself, equal to its own `id`. |
| `author` | string | yes | Author's public key (base64url). |
| `seq` | int | yes | Author's record number. Starts at 1, increases by exactly 1. |
| `prevHash` | string | yes | Hex SHA-256 of the author's previous record (Section 4.3). For `seq = 1`: 64 zeros. |
| `type` | string | yes | One of the types in Section 5. |
| `body` | object | yes | Type-specific fields (Section 5). Use `{}` when empty. |
| `refersTo` | string or null | yes | `id` of the record this one targets, or `null`. |
| `note` | string | yes | Free text, may be `""`. Max 500 characters. |
| `time` | string | yes | Author's clock, ISO 8601 UTC (`2026-10-02T10:15:00Z`). **Display only.** |
| `sig` | string | yes | Ed25519 signature, base64url without padding (Section 4.2). |

All money amounts inside `body` are **integers in paisa** (1 PKR = 100 paisa) and must be `> 0`.

**One partnership per ledger.** A ledger holds exactly one partnership, named by the `id` of its accepted
`partnership_create`. A record whose `partnership` is different is rejected (Section 6.1, step 3). This
includes a second `partnership_create`. If the manager rejects a create, the investor makes a new create.
That is a new partnership with its own ledger, and the rejected one stays as history.

**Chains are per partnership.** `seq` and `prevHash` belong to a (partnership, author) pair. Each partner's
`seq` starts at 1 in each partnership.

---

## 4. Canonical encoding, signatures and hashes

### 4.1 Canonical JSON

To sign or hash a record, encode it as canonical JSON:

- Object keys sorted by Unicode code point, recursively (including inside `body`).
- No whitespace anywhere.
- Strings in UTF-8 with standard JSON escaping; integers in plain decimal; no floats anywhere.
- `null` written as `null`.

"Unicode code point" means the number of the character itself (U+0041 for `A`, U+1F600 for an emoji).
Sorting by UTF-16 code units gives a different order for characters above U+FFFF, so do not use it.
In v1 all keys are ASCII, so the two orders agree today; the rule is still stated exactly.

`canonical(x)` below means the UTF-8 bytes of this encoding.

**Canonical form on receive.** A record received as text is accepted only if the text is already
canonical: parse it, encode it again with this section's rules, and the result must equal the received
text byte for byte. This refuses extra whitespace, keys in the wrong order, duplicate keys (a parser
keeps only one, so two parsers could disagree) and `[]` where `{}` belongs. Every device stores the same
bytes, so every hash and signature means the same thing everywhere.

### 4.2 Signature

```
unsigned = record without the "sig" field
sig      = base64url( Ed25519_sign(privateKey, canonical(unsigned)) )
```

### 4.3 Record hash

```
hash(record) = hex( SHA-256( canonical(record including "sig") ) )
```

`prevHash` of record with `seq = n` must equal `hash` of the same author's record with `seq = n − 1`.
Both `seq` and `prevHash` are counted per (partnership, author), see Section 3.

---

## 5. Record types

Records marked **needs approval** only take effect when the **other partner**'s **first response**
(see below) to that record is an `approve`. A decision is monotonic: it moves from **pending** to
**active** (first response is `approve`) or from **pending** to **dead** (first response is `reject`),
and never moves back.

**First response rule:** for a given target record, look at the other partner's `approve`/`reject`
records whose `refersTo` is that target, and take the one with the **lowest `seq`** (the earliest one
the author ever made — not the one that happened to arrive first over the network). Only that first
response counts. Any later `approve`/`reject` from the same author to the same target is stored as
evidence but is **ignored** in all calculations, and the UI shows it as "ignored: later response."
To change their mind, a partner must create a new proposal, not a new response.

This is deterministic on every device: by spec §6.1 step 4, an author's record at `seq = n` cannot be
validated before their record at `seq = n − 1` (gaps are buffered), so every device evaluates an
author's responses in the same `seq` order regardless of network arrival order.

| Type | Allowed author | `body` | `refersTo` | Effect |
| --- | --- | --- | --- | --- |
| `partnership_create` | investor | `{ "investor": key, "manager": key, "ratio": {"investor": int, "manager": int}, "currency": "PKR" }` | null | Proposes the partnership. Ratio values are whole percentages summing to 100, and each is 1 to 99 (a 0 or 100 share is refused: both partners share in the profit). **Needs approval** (by manager). |
| `invest` | investor | `{ "amount": int }` | null | Adds capital. |
| `sale` | manager | `{ "amount": int }` | null | Adds income. |
| `budget_proposal` | either | `{ "grantee": key, "amount": int }` | null | Proposes a spending limit for the grantee. **Needs approval.** |
| `expense` | manager | `{ "amount": int, "receiptHash": string or null }` | `id` of an approved `budget_proposal` whose grantee is the author | Removes money, drawn from that budget (Section 6.4). |
| `withdraw_request` | either | `{ "amount": int, "kind": "capital" or "profit" }` | null | Money taken out of the fund. **Needs approval.** |
| `ratio_proposal` | either | `{ "ratio": {"investor": int, "manager": int}, "effectiveFrom": "YYYY-MM-DD" }` | null | Proposes a new ratio, with the same 1 to 99 rule for each share. **Needs approval.** |
| `reversal` | either | `{}` | `id` of the record to cancel | Cancels a record (Section 6.3). Only `invest`, `sale`, `expense` and `withdraw_request` can be reversed. Reversing the other partner's record **needs approval**. |
| `approve` | either | `{}` | `id` of a record that needs approval | Approves it. Must not be authored by the target's author. |
| `reject` | either | `{}` | same as `approve` | Rejects it. |
| `settlement` | manager only | `{ "cut": { "<investorKey>": int, "<managerKey>": int } }` | null | Closes a period of the ledger (Section 6.7). **Needs approval** by the investor. *Planned, not built.* |

Notes:

- The partnership's two keys are fixed by the approved `partnership_create`. Records from any other key are invalid.
- Until `partnership_create` is approved, only `partnership_create` and the manager's `approve`/`reject` of it are valid.
- Only `invest`, `sale`, `expense` and `withdraw_request` can be reversed in v1. A `reversal` whose target is any other type (`partnership_create`, `approve`, `reject`, `reversal`, `ratio_proposal`, `budget_proposal`) is **invalid**: it is flagged and shown in the UI, and has no effect. Reasons: reversing `partnership_create` would destroy the partnership; reversing an active `ratio_proposal` would flip a decision backward (propose a new ratio instead); closing a `budget_proposal` early raises a cross-author ordering question, so it is future work; responses are final under first-response-wins (propose again instead).
- A `reversal` of a `reversal` is therefore invalid in v1. Reversing a needs-approval record that is already approved is allowed (it cancels its effect).

---

## 6. Validation and calculation rules

### 6.1 Receiving a record (per record, in this order)

1. **Schema:** the text is in canonical form (Section 4.1, byte for byte). All fields present with correct
   types; `v == 1`; amounts are positive integers. For a `partnership_create`, `partnership` equals its own
   `id`. No key other than the fields in Section 3 at the top level, and no key in `body` other than the
   ones Section 5 lists for that `type`; a `ratio` object has exactly `investor` and `manager`. A `type`
   not in Section 5 is invalid.
2. **Signature:** `sig` verifies against `author` over `canonical(unsigned)`.
3. **Membership:** `partnership` equals this ledger's partnership id (the `id` of its accepted
   `partnership_create`), and `author` is one of the two partnership keys. Before any create is accepted,
   only a `partnership_create` passes (the bootstrap case in Section 5), and only if it matches the keys
   pinned by the join code (Section 2.1). A second `partnership_create` fails here.
4. **Chain:** if the author's record with `seq − 1` is present, `prevHash` must match its hash.
   If it is missing, keep the record in a **pending** buffer until the gap is filled. Pending records are not used in calculations.
5. **Equivocation:** if a different record already exists with the same `author` and `seq`, keep **both**,
   mark the author as **equivocating**, and show a warning. Both records stay as evidence. Neither is used in calculations from that `seq` on, until resolved by the partners outside the app.
6. **Duplicate:** a record with an `id` already present and the same hash is ignored. Same `id` with a different hash → reject and flag.

Records that fail steps 1–3 are rejected (not stored). Records that pass are stored even if later rules mark them as **invalid**; invalid records are kept as evidence but have no effect.

### 6.2 Deterministic evaluation order

Calculations process each author's valid records in ascending `seq` order. When records from both
authors must be combined, sort by `(author, seq)`. Never depend on arrival order or on `time`.

### 6.3 Effective records

A record is **effective** when all are true:

- it passed 6.1 and is not pending;
- if it needs approval, its first-response decision (Section 5) is **active**, not **dead**;
- it is not cancelled by an effective `reversal`;
- its type-specific checks pass (6.4).

A `reversal` is effective if its target exists and either the reversal's author is the target's author,
or the reversal is approved by the other partner.

### 6.4 Budgets

Budget status is **monotonic**: once an expense is judged valid or over-budget, that judgement
never changes later. For each effective `budget_proposal` B, process records that target it
(expenses and reversals of those expenses) in `seq` order, keeping one running total, `used`:

```
used = 0
for each record R targeting B, in seq order:
    if R is an expense:
        if used + R.amount <= B.amount:
            R.status = valid
            used += R.amount
        else:
            R.status = overBudget   # final — R.status never changes again
    if R is a reversal of a VALID expense:
        used -= that expense's amount   # frees budget from here onward only
    if R is a reversal of an OVER-BUDGET expense:
        # nothing to free: the expense was never counted towards `used`
```

**Position of each event.** `seq` is per author, so records from the two partners cannot be ordered
against each other. Every budget event is therefore placed at a `seq` from the **grantee's** chain
(the manager, who is the only author of expenses):
- an `expense` sits at its own `seq`;
- a reversal by the grantee sits at its own `seq`;
- a reversal by the other partner sits at the `seq` of the grantee's `approve` that makes it effective.

Since the other partner's reversal needs the grantee's approval (Section 5), this position is always known.

An expense's status depends only on `used` as it stood at that expense's own `seq` — a fact fixed
the moment the expense was evaluated. A later reversal can only change `used` **from its own `seq`
onward**, for expenses still to come; it can never reach back and flip an earlier expense's status.
Invalid (over-budget) expenses do not count towards `used` and are flagged to both partners.

### 6.5 Money calculations

All sums use only effective records.

```
capital        = Σ invest.amount − Σ withdraw_request(kind = capital).amount
cash_balance   = Σ invest + Σ sale − Σ expense − Σ withdraw_request (both kinds)
result         = Σ sale − Σ expense
profit_paid    = Σ withdraw_request(kind = profit)
```

v1 measures **realized** results only: unsold stock is not valued. Valuing stock is future work.
`profit_paid` must never exceed the profit owed by the active ratio; the app warns before approval.

- If `result > 0` it is **profit**, shared by the active ratio (6.6). Shares are computed in paisa;
  any remainder from integer division goes to the investor (recorded in `docs/decisions.md`).
- If `result < 0` it is a **loss**, carried by the investor (the manager's share of loss is 0),
  unless the partners record otherwise outside the app.
- `budget_left(B) = B.amount − used(B)`.

The app should warn (not block) when an approval would make `cash_balance` or total open budgets exceed available money.

### 6.6 Active ratio

**Current build (until settlement is built).** The active ratio is decided by the records alone, with **no
clock** (hard rule 3): the last effective `ratio_proposal` in `(effectiveFrom, author, seq)` order. If there is
none, it is the ratio in the approved `partnership_create`. This ratio is applied to the **whole** result. That
re-splits profit earned before a change, which is a known issue (see `docs/decisions.md`, 2026-10-05). The
`effectiveFrom` date is a sort key and display text only.

**Target rule (applies once settlement is built, Section 6.7).** The ledger is split into periods by effective
settlements. Each period has one ratio, and the ratio is fixed when the period starts. A change never applies to
earned profit it did not cover.

- Period 1 uses the ratio in the approved `partnership_create`.
- Period k (k ≥ 2) uses the last effective `ratio_proposal` whose approval is inside the cut of period k−1,
  sorted by `(effectiveFrom, author, seq)`. If there is none, it uses the ratio of period k−1.
- The open period (after the last effective settlement) uses the same rule as period k, with the last cut.
  So an approved change waits for the next settlement before it applies. The dashboard shows that a change is
  waiting.
- No clock is used at any step. `effectiveFrom` is a sort key and display text only.
- The ratio is shown as text, for example `50/50 (agreed to start 2026-11-01)`.

### 6.7 Settlement (planned, not built)

**Status:** Design decided on 2026-10-05 (see `docs/decisions.md`). Build order: core first, then the app
approvals inbox. Until then, Section 6.6 "Current build" applies.

**Record.** A `settlement` is authored by the **manager only**. Its body is
`{ "cut": { "<investorKey>": int, "<managerKey>": int } }`. It has no `refersTo`. The investor approves it. A
settlement stores **no money totals**. The period result is calculated from the cut (hard rule 4).

**Cut rules.** A settlement is valid only if all of these hold. They check the set of records, never the arrival
order.

1. The cut has exactly the two partnership keys, and each value is a non-negative integer.
2. The manager's value is lower than the settlement's own `seq`. A settlement never covers itself.
3. The cut is **closed**. Every record inside the cut that refers to another record refers to one inside the
   cut. Every record inside the cut that needs approval is decided (approved or rejected) by a record inside the
   cut.
4. The cut **dominates** the previous effective settlement's cut: each value is at least that cut's value for
   the same key (0 if there is none).
5. The cut is **not empty**: at least one value is larger than the previous cut's value.

**Ordering rule.** Settlement proposals are decided in order. Let S_k be the k-th settlement by manager `seq`. An
investor's `approve` or `reject` of S_k is valid only if the investor has already responded to every S_j (j < k)
at a lower investor `seq` than this response. Otherwise the response is invalid and flagged. A phone can decide
this once it holds the investor's chain up to that `seq`, because chains have no gaps (Section 7.1). A response
that arrives before its predecessors is pending, not invalid.

*Consequence:* at most one settlement waits for the investor's answer at a time. The investor cannot approve S_2
before S_1.

**Effective.** A settlement is effective when it is valid under the cut rules and approved under the ordering
rule. If it fails rule 4 against the previous effective settlement, it is invalid and flagged.

**Periods.** Let cut_0 be empty. The effective settlements, in order, give cut_1, cut_2, and so on. Period k is
the records inside cut_k and not inside cut_(k−1). The open period is the records after the last effective cut.

**Shares per period.** For each period, compute its result from its effective records (Section 6.5). Then:

- **Loss carry-forward.** Keep a deficit D, starting at 0. For each period in order, with `net` = the period's
  result:
  - If `net < 0`: add `-net` to D. The investor bears the loss. The manager gets 0.
  - If `net > 0`: `cover = min(D, net)`, then `D = D - cover`. The distributable amount is `net - cover`. Split it
    at the period's ratio.
  - If `net = 0`: nothing changes.

  Capital is restored first: a loss is covered by later profit before any profit is shared.
- **Rounding.** Each period is split on its own with `splitResult` (Section 6.5). The shares summed over all
  periods can differ by up to one paisa per period from one split of the whole result. This is deterministic and
  accepted.

**Prior-period adjustments.** A `reversal` of a record in an earlier period is allowed. Its effect is booked in the
period where the reversal and its approval first fall inside a cut together. The adjustment is split at the ratio
of the period that contains the reversed record. It is shown as a separate line, "correction from an earlier
period". A settled period never changes. **Open:** whether an adjustment enters the deficit account. See
`docs/decisions.md`, 2026-10-05.

**Limitations (v1), documented:**

- Only the manager proposes settlements. In the app, the investor cannot force a settlement. The investor can only
  approve or reject one.
- Losses are carried forward only. Provisional profit distributions made before a later loss are not clawed back.
  This is future work.
- Profit withdrawals are not capped by settled shares. The approval screen shows the ratio-change warning and each
  partner's settled share for reference.

---

## 7. Sync protocol

### 7.1 Version vector

A device's version vector is a map `author → highest seq held without gaps`, **for one partnership**. A
device holding two partnerships keeps one version vector per partnership, never one shared across them.
Example, for one partnership: `{ "<investorKey>": 12, "<managerKey>": 7 }`.

### 7.2 Relay API (Laravel)

All endpoints are JSON over HTTPS, prefix `/api/v1`. Records travel as the **exact canonical JSON
string** the author produced; the relay stores that string unchanged.

**Device registration** takes two steps. A public key is public, so a key alone proves nothing: without a
proof of possession, anyone could register as a partner's device and download the whole ledger.

1. **`POST /devices/challenge`** — request a nonce.
   Request: `{ "publicKey": string }` → Response `201`: `{ "nonce": string, "expiresAt": string }`.
   The nonce is 32 random bytes in base64url without padding (43 characters). It is single use, expires
   5 minutes after it is issued, and is stored on the relay for that key.
2. **`POST /devices`** — register the key with proof.
   Request: `{ "publicKey": string, "nonce": string, "signature": string }`
   → Response `201`: `{ "token": string }` (Sanctum token). Otherwise `422`.
   The signature is Ed25519 over the UTF-8 bytes of `"qiradsync-register-v1:" + nonce` (the prefix is the
   domain separator, so a registration signature can never be a record signature, Section 4.2).
   The relay deletes the nonce as soon as it is presented, whether the registration succeeds or fails.
   A nonce that is unknown, expired, issued for another key, or already used is refused, as is a
   signature over the bare nonce without the prefix.

**`POST /partnerships/{partnershipId}/sync`** — exchange records (auth: bearer token).

Request:
```json
{ "vector": { "<key>": 12 }, "records": ["<canonical record json>", "..."] }
```

Relay behaviour:

1. For each uploaded record, in canonical form (Section 6.1 step 1): check its `partnership` matches the URL
   and its signature is valid. A `partnership_create` in the batch is handled first, then the other records
   in any order. The relay does not check `seq` order; each phone does (Section 6.1).
   - If no record exists with the same `(author, seq)`, store it in `records`.
   - If the same record (same hash) is already stored, report it in `already`. Nothing is stored twice.
   - If a record exists with the same `(author, seq)` but a **different** hash, do not overwrite it. Store the
     new version in `conflicts` (a separate table, append-only). Report it in `conflicts` as well.
2. Only devices whose public key is one of the two keys named in the partnership's accepted `partnership_create`
   may sync. Before a `partnership_create` is stored, only the investor's device may sync, and only to upload a
   valid `partnership_create` signed by the investor. Once it exists, both keys may sync, including the manager
   before approving. The relay does not interpret approvals.
3. Return every stored record of this partnership with `seq` greater than the client's vector for its author,
   ordered by `(author, seq)`, plus the relay's own vector.
4. **Equivocation goes to both partners.** The `conflicts` list in every response holds, for each `(author, seq)`
   that has a conflict, **every** version the relay holds at that position: the stored record and each conflicting
   version. It is returned to every member of the partnership, on every sync, not only to the device that
   uploaded the conflict. Each phone runs its own equivocation check (Section 6.1 step 5). A partner who
   equivocates therefore cannot hide it from the other partner.

The relay's vector in the response is **always computed live** from what it currently holds, using
the same gap-aware rule as Section 7.1 (highest `seq` held *without gaps*, per author) — never cached.
This is what lets a client detect that the relay lost data (Section 7.3): a relay that is missing
records reports a lower vector, it never reports a stale or remembered one.

Response:
```json
{
  "accepted": ["<id>"],
  "already": ["<id>"],
  "rejected": [{ "index": 0, "reason": "<short reason>" }],
  "conflicts": ["<canonical record json>"],
  "records": ["<canonical record json>"],
  "vector": { "<key>": 14 }
}
```

`accepted` lists the ids stored by this request. `already` lists ids that were sent again unchanged. `rejected`
lists records refused by the checks above, with the position in the request. The reasons are for debugging only,
never for decisions. A device that is not allowed to sync gets `403` with a fixed message.

The relay never edits, deletes, merges or interprets record content beyond the checks above.

### 7.3 Client sync loop

1. Collect candidate records to send. A local guess about what the relay probably already has may be
   used here as a bandwidth shortcut, but that guess is **never trusted for correctness** — step 3
   is what guarantees the relay ends up complete, regardless of whether this guess was right.
2. Call `sync` with the local vector and those candidate records.
3. **Compare and repair:** check the relay's returned vector (always freshly computed, Section 7.2)
   against the local vector, for **every** author the client holds records for — including the other
   partner, since any device may re-upload any valid signed record it holds, not only its own (the
   relay only checks a record's own signature, never who uploaded it). If the relay's vector for an
   author is lower than the local vector, the client holds records the relay is missing: upload them
   immediately, in another `sync` call, before continuing. Repeat until the relay's vector matches the
   local vector for every author, or after **3 repair rounds**, whichever comes first (then fall through to
   step 6 — don't hang the app on a relay that keeps failing to persist). A repair round is one upload in
   this step. The count is per sync run, and it is separate from network retries in step 6: a retry starts
   a new run with its own 3 repair rounds, and no retry uses or adds to this count.
4. Run every returned record and conflict through 6.1, then add valid ones to the ledger.
5. Recalculate (Section 6) and refresh the UI.
6. Retry with exponential backoff when a failure may go away: a network error, a call that times out
   (no answer within 30 seconds, and a connection that does not open within 10 seconds), or a relay
   `5xx` status. Each wait is 1 s, then 2 s, 4 s and so on, capped at 30 s, and there are at most 5
   retries. Never retry a `4xx` status, with one exception: a `401` makes the phone register again
   (spec 7.2) and resend the same batch, once. A second `401` in the same run stops the sync with a clear
   error. A `403` or `422` gives the same answer again, so it is not retried. Retries are safe because sync is
   idempotent: the relay reports a record it already holds as `already`, so repeating a sync never
   stores a record twice, and the repair rounds in step 3 run again from the start.

Never rely on a cached belief about what the relay holds to decide the sync is finished — only the
relay's own freshly-returned vector, checked every time, can say that. This is what lets the ledger
recover automatically if the relay ever loses data (e.g. a database restore): the very next sync from
either partner's phone notices the gap and refills it, with no manual restore step.

---

## 8. Required tests (minimum)

- **Merge properties:** for random sets of valid records, merging in random orders, groupings and with
  duplicates always gives identical ledgers and identical calculation results (use fixed random seeds).
- **Signature:** a record with any field changed after signing is rejected.
- **Chain:** gaps are buffered; a wrong `prevHash` is detected.
- **Equivocation:** two records with same `(author, seq)` and different content flag the author.
- **Approvals:** needs-approval records have no effect until approved; **first response wins**:
  approve (seq 5) then reject (seq 9) from the same author → stays **approved**; reject (seq 5) then
  approve (seq 9) → stays **dead**; a late-arriving second response never changes an already-active
  (or already-dead) decision.
- **Reversals:** own reversal works; reversing the other partner's record needs approval.
- **Budgets:** an expense beyond its budget is flagged and excluded; status is monotonic once set.
  Case (budget 10,000): E1 4,000, E2 3,000, E3 5,000, E4 2,000, then R5 reverses E2. Expected:
  E1 valid; E2 valid, then reversed; E3 stays flagged over-budget even after E2's reversal frees
  room; E4 valid; final `used` = 6,000, budget left = 4,000.
- **Money:** profit and loss cases, remainder rule, ratio change by `effectiveFrom`.
- **Relay:** stores exact strings, rejects bad signatures, reports conflicts, returns only missing records.
- **Sync recovery:** wipe the relay's database, then run the next sync from either phone — the relay
  must end up holding every record that exists on either phone (Section 7.3's compare-and-repair step).
