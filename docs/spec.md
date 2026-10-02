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

---

## 4. Canonical encoding, signatures and hashes

### 4.1 Canonical JSON

To sign or hash a record, encode it as canonical JSON:

- Object keys sorted by Unicode code point, recursively (including inside `body`).
- No whitespace anywhere.
- Strings in UTF-8 with standard JSON escaping; integers in plain decimal; no floats anywhere.
- `null` written as `null`.

`canonical(x)` below means the UTF-8 bytes of this encoding.

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
| `partnership_create` | investor | `{ "investor": key, "manager": key, "ratio": {"investor": int, "manager": int}, "currency": "PKR" }` | null | Proposes the partnership. Ratio values are percentages summing to 100. **Needs approval** (by manager). |
| `invest` | investor | `{ "amount": int }` | null | Adds capital. |
| `sale` | manager | `{ "amount": int }` | null | Adds income. |
| `budget_proposal` | either | `{ "grantee": key, "amount": int }` | null | Proposes a spending limit for the grantee. **Needs approval.** |
| `expense` | manager | `{ "amount": int, "receiptHash": string or null }` | `id` of an approved `budget_proposal` whose grantee is the author | Removes money, drawn from that budget (Section 6.4). |
| `withdraw_request` | either | `{ "amount": int, "kind": "capital" or "profit" }` | null | Money taken out of the fund. **Needs approval.** |
| `ratio_proposal` | either | `{ "ratio": {"investor": int, "manager": int}, "effectiveFrom": "YYYY-MM-DD" }` | null | Proposes a new ratio. **Needs approval.** |
| `reversal` | either | `{}` | `id` of the record to cancel | Cancels a record (Section 6.3). Reversing the other partner's record **needs approval**. |
| `approve` | either | `{}` | `id` of a record that needs approval | Approves it. Must not be authored by the target's author. |
| `reject` | either | `{}` | same as `approve` | Rejects it. |

Notes:

- The partnership's two keys are fixed by the approved `partnership_create`. Records from any other key are invalid.
- Until `partnership_create` is approved, only `partnership_create` and the manager's `approve`/`reject` of it are valid.
- A `reversal` of a `reversal` is invalid in v1. Reversing a needs-approval record that is already approved is allowed (it cancels its effect).

---

## 6. Validation and calculation rules

### 6.1 Receiving a record (per record, in this order)

1. **Schema:** all fields present with correct types; `v == 1`; amounts are positive integers.
2. **Signature:** `sig` verifies against `author` over `canonical(unsigned)`.
3. **Membership:** `author` is one of the two partnership keys (except the bootstrap case in Section 5).
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

For each effective `budget_proposal` B:

```
used(B) = sum of amounts of expenses E where E.refersTo == B.id, E is not reversed,
          processed in E.author's seq order
```

An expense is **invalid (over budget)** if `used(B)` before it plus its amount would exceed `B.amount`.
Invalid expenses do not count towards `used(B)` and are flagged to both partners.

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

Start with the ratio in the approved `partnership_create`. Then apply effective `ratio_proposal`
records sorted by `(effectiveFrom, author, seq)`. For a given date D, the active ratio is the latest
one whose `effectiveFrom <= D`. v1 shows the ratio active today; per-period profit split is future work.

---

## 7. Sync protocol

### 7.1 Version vector

A device's version vector is a map `author → highest seq held without gaps`. Example:
`{ "<investorKey>": 12, "<managerKey>": 7 }`.

### 7.2 Relay API (Laravel)

All endpoints are JSON over HTTPS, prefix `/api/v1`. Records travel as the **exact canonical JSON
string** the author produced; the relay stores that string unchanged.

**`POST /devices`** — register a device.
Request: `{ "publicKey": string }` → Response: `{ "token": string }` (Sanctum token).

**`POST /partnerships/{partnershipId}/sync`** — exchange records (auth: bearer token).

Request:
```json
{ "vector": { "<key>": 12 }, "records": ["<canonical record json>", "..."] }
```

Relay behaviour:

1. For each uploaded record: check it parses, its `partnership` matches the URL, and its signature is valid.
   Store it if no record exists with the same `(author, seq)`.
   If one exists with a **different** hash, do not overwrite: return it in `conflicts` (evidence of equivocation).
2. Only devices whose public key is a party in that partnership's `partnership_create` may sync
   (exception: the manager key named in it may sync before approving).
3. Return every stored record of this partnership with `seq` greater than the client's vector for its author,
   ordered by `(author, seq)`, plus the relay's own vector.

The relay's vector in the response is **always computed live** from what it currently holds, using
the same gap-aware rule as Section 7.1 (highest `seq` held *without gaps*, per author) — never cached.
This is what lets a client detect that the relay lost data (Section 7.3): a relay that is missing
records reports a lower vector, it never reports a stale or remembered one.

Response:
```json
{ "accepted": ["<id>"], "conflicts": ["<canonical record json>"], "records": ["<canonical record json>"], "vector": { "<key>": 14 } }
```

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
   local vector for every author, or after 3 attempts, whichever comes first (then fall through to
   step 6 — don't hang the app on a relay that keeps failing to persist).
4. Run every returned record and conflict through 6.1, then add valid ones to the ledger.
5. Recalculate (Section 6) and refresh the UI.
6. Retry with exponential backoff when offline. Sync (including the repair rounds in step 3) is safe
   to repeat any number of times.

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
- **Budgets:** an expense beyond its budget is flagged and excluded.
- **Money:** profit and loss cases, remainder rule, ratio change by `effectiveFrom`.
- **Relay:** stores exact strings, rejects bad signatures, reports conflicts, returns only missing records.
- **Sync recovery:** wipe the relay's database, then run the next sync from either phone — the relay
  must end up holding every record that exists on either phone (Section 7.3's compare-and-repair step).
