# Tethered

A private long-distance couples app. Flutter client, Supabase backend, sideloaded — it is not on any
store and is not intended to be.

The Android build ships **disguised**: the launcher shows "News" with a matching icon, and the real app
is behind a cover screen plus a biometric gate. That is deliberate. Do not "fix" it.

## Layout

| Path | What lives there |
|---|---|
| `mobile/` | The Flutter app. This is the product. |
| `mobile/lib/core/` | Cross-feature machinery: session, router, theme, realtime, services, diagnostics. |
| `mobile/lib/features/` | One directory per feature. Screens, controllers and repositories stay together. |
| `mobile/test/` | Unit and widget tests. `flutter test` must be green before anything ships. |
| `supabase/migrations/` | The database, in replay order. The **only** place DDL belongs. |
| `supabase/functions/` | Edge Functions (Deno). |
| `scripts/` | Operational one-offs. |
| `docs/` | See below. |

## Documentation

- [`docs/REFERENCE.md`](docs/REFERENCE.md) — what every module does. Start here.
- [`docs/FIELD-TEST.md`](docs/FIELD-TEST.md) — how to run a two-phone test and read the trace.
- [`docs/architecture/`](docs/architecture/) — the scaling design work: roadmap, contract, per-domain designs.
- [`docs/guides/`](docs/guides/) — build plan, performance plan, design system.
- [`docs/archive/`](docs/archive/) — superseded. Kept for history; do not treat as current.

## Build

```bash
cd mobile
flutter pub get
flutter test
flutter build apk --release
```

`cd mobile` first — running `flutter` from the repo root fails with "No pubspec.yaml".

The APK is debug-signed on purpose (private distribution). If a phone refuses to install, uninstall the
old copy first: a different signing key will not upgrade in place.

## Configuration

`mobile/.env` is required and is never committed. See [`mobile/.env.example`](mobile/.env.example) for
the keys.

Per-environment server values (the Edge Function base URL, the Cloudflare TURN credentials) live in the
`app_secrets` table, one row per Supabase project — not in the repo and not in the APK.

## Working rules

Enforced by `mobile/test/unit/repo_hygiene_test.dart`, not by good intentions:

- **No dead code.** An unreferenced symbol, file, asset or dependency is deleted, not commented out.
- **No commented-out code.** Git remembers it.
- **DDL only in `supabase/migrations/`,** with a 14-digit ordering prefix.
- **Comments explain why.** A comment that restates the next line is noise; a comment naming the failure
  a line prevents is worth keeping.
