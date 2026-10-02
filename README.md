# QiradSync

An offline-first ledger for **Mudaraba** (Islamic profit-sharing) partnerships between two
partners: one investor (Rabb-ul-Mal) and one manager (Mudarib).

Every phone holds the full ledger. Records are signed and chained per author, and devices merge
their ledgers as a grow-only set (CRDT) — any two devices that have seen the same records reach the
same balances, in any sync order. The server only stores and forwards records; it never validates,
merges, or interprets them.

See [`docs/spec.md`](docs/spec.md) for the exact rules, [`docs/plan.md`](docs/plan.md) for the
build phases, and [`docs/decisions.md`](docs/decisions.md) for decisions made along the way.

## Repository layout

```
packages/qirad_core/   pure Dart: record model, ledger, merge, validation, calculations
apps/mobile/           Flutter app: UI, local storage, sync client
relay/                 Laravel app: stores and forwards records, decides nothing
docs/                  spec, plan, design report, decisions log
```

## Setup

### Core library (`packages/qirad_core`)

```
cd packages/qirad_core
dart pub get
dart test
dart analyze
```

### Mobile app (`apps/mobile`)

```
cd apps/mobile
flutter pub get
flutter test
flutter analyze
```

### Relay (`relay`)

```
cd relay
composer install
cp .env.example .env   # already done for local dev; .env is not committed
php artisan key:generate
php artisan migrate
php artisan test
```
