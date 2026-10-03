# QiradSync v1 — Implementation Plan

Work one phase at a time, on its own branch. A phase is done only when every checkbox is ticked,
all tests pass, and its pull request is merged.

---

## Phase 0 — Repository setup

- [ ] Create the layout: `packages/qirad_core`, `apps/mobile`, `relay`, `docs`
- [ ] `qirad_core`: `dart create -t package`, add `uuid`, `crypto`, `cryptography`, `test`, `lints`
- [ ] `apps/mobile`: `flutter create`, depend on `qirad_core` via path
- [ ] `relay`: new Laravel project with Sanctum installed
- [ ] Keep the existing root `.gitignore`; extend it if new tools need it
- [ ] `README.md` with project summary and setup steps
- [ ] GitHub repository created and `main` pushed
- [ ] `docs/decisions.md` created with a short template (date, decision, reason)
- [ ] All three projects build and their empty test suites pass

**Done when:** a fresh clone can run the tests of all three projects successfully.

---

## Phase 1 — Record model and canonical encoding

- [x] `Record` model with all fields from spec §3, immutable, `fromJson` / `toJson`
- [x] `canonicalJson()` exactly as spec §4.1
- [x] `recordHash()` as spec §4.3
- [x] Tests: key ordering, nested `body` ordering, no whitespace, round-trip parse/encode, known hash vector

**Done when:** encoding the same record on any device always yields identical bytes (tested).

---

## Phase 2 — Ledger and merge

- [x] `Ledger` holding records by `id` (G-Set)
- [x] `merge(other)` = union by `id`, duplicate handling per spec §6.1 step 6
- [x] Version vector computed from the ledger (spec §7.1)
- [x] **Property tests**: random orders, groupings and duplicates give identical ledgers

**Done when:** property tests pass for at least 1,000 random cases with fixed seeds.

---

## Phase 3 — Keys, signatures and chains

- [x] Ed25519 key generation, `sign(record)`, `verify(record)`, base64url helpers
- [x] Validation pipeline spec §6.1 steps 1–6, including pending buffer and equivocation flag
- [x] Tests: tampered field rejected, wrong `prevHash` detected, gap buffered then released, equivocation flagged

**Done when:** every attack in the design report's threat table that applies to records has a passing test.

---

## Phase 4 — Business rules and calculations

- [x] Approvals and rejects (first response wins), spec §5
- [x] Reversals, spec §6.3
- [x] Budgets and over-budget detection, spec §6.4
- [x] Money calculations and remainder rule, spec §6.5
- [x] Active ratio, spec §6.6
- [x] Scenario tests for each rule, plus "same records in any order → same results"

**Done when:** all spec §8 tests for these rules pass.

---

## Phase 5 — Relay server

- [x] Migrations: `devices`, `records` (stores raw canonical string, `partnership`, `author`, `seq`, `hash`, `id`), unique index on `(partnership, author, seq)`
- [x] No UPDATE or DELETE on `records` anywhere
- [x] `POST /api/v1/devices` and `POST /api/v1/partnerships/{id}/sync` exactly per spec §7.2
- [x] Ed25519 signature check in PHP (`sodium_crypto_sign_verify_detached`), using the same canonical string
- [x] Feature tests: stores exact strings, rejects bad signature, returns only missing records, reports conflicts, blocks non-members

**Done when:** a record signed in Dart verifies in PHP (shared test vector) and all feature tests pass.

---

## Phase 6 — Mobile storage and sync

- [ ] SQLite tables for records (raw canonical string + indexed fields) and pending buffer
- [ ] Secure storage for the private key
- [x] Sync client per spec §7.3: one sync run with compare-and-repair (up to 3 repair rounds)
- [ ] Sync retry with exponential backoff when offline (network retries are counted apart from repair rounds)
- [ ] Join flow with pinned keys per spec §2.1: join code (partnership id + investor key); the validator rejects any create that does not match the pins. Done before registration.
- [ ] Device registration per spec §7.2 (challenge, signed registration). The token is stored in secure storage. On a 401, re-register once and retry the sync. A second 401 stops with a clear error.
- [x] Partnership scoping: queries and version vectors always take a partnership id
- [ ] Integration test: two simulated devices + local relay, offline edits on both, converge after sync

**Done when:** the two-device test converges with identical balances.

---

## Phase 7 — App screens

- [ ] Onboarding: create keys, create or join partnership (share partnership id by QR code or text)
- [ ] Dashboard: capital, cash balance, result, each partner's share, active ratio
- [ ] Transactions list with filters, and record detail showing author, signature status and links
- [ ] Forms: invest, sale, expense (choose budget, optional receipt photo hash), withdraw, budget, ratio, reversal
- [ ] Approvals inbox: pending items with approve / reject
- [ ] Warnings: over-budget, equivocation, chain problems
- [ ] Sync status indicator and manual "sync now"

**Done when:** a full Mudaraba month can be simulated on two phones (or emulators) end to end.

---

## Phase 8 — Evaluation and write-up

- [ ] Run every scenario in the design report Section 9.1 and record results
- [ ] Measure sync size (full vs delta) for 100 / 1,000 / 10,000 records
- [ ] Measure verification and recalculation time on a real mid-range Android phone
- [ ] Update the design report with results, limitations found and next steps
- [ ] Clean README with screenshots, setup steps and a short demo video link

**Done when:** the report's evaluation section contains real numbers with device model and run count.

## Before the first release

- [ ] Database schema migration path: versioned upgrades for the phone's SQLite file (the schema is version 1 with no upgrade step yet)
