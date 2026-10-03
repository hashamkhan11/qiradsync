# Shared test fixtures

These files are the shared bytes that the Dart core and the PHP relay must agree on.
**Never edit them by hand.** A test fails if a file is out of date.

| File | Written by | Read by | What it is |
|---|---|---|---|
| `dart_signed_records.json` | `dart run tool/generate_fixtures.dart` (in `packages/qirad_core`) | PHP `SharedFixturesTest` and Dart `fixtures_test.dart` | Three records signed in Dart: create, invest, approve. One has a non-ASCII note, one has an empty body. Includes the expected SHA-256 hash of each. |
| `relay_equivocation_sync.json` | `QIRAD_WRITE_FIXTURES=1 php artisan test --filter=SharedFixturesTest` (in `relay/`) | Dart `relay_fixture_test.dart` | A real sync response from the relay. The manager uploads two versions of seq 5, and the investor's next sync gets both. |

## How the checks work

- **Dart -> PHP:** the relay checks the signature, the canonical form and the hash of each
  record, then stores them through the sync endpoint.
- **PHP -> Dart:** the Dart validator reads the relay response through `receiveText`
  and must flag the manager for equivocation at seq 5.
- **Freshness:** the Dart test regenerates the Dart file and compares it. The PHP test
  regenerates the relay file and compares the bytes. A stale file fails the test.

## Test keys only

The keys used to make these files are derived from fixed labels (`qiradsync test key: investor`
and so on). They guard nothing. That is what makes the files the same on every run.
Never use them for a real partnership.
