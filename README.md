# Miles

A private long-distance couples app. Flutter client, Supabase backend, end-to-end encrypted.
One app: it ships on Google Play as **Miles** (package `com.miles.miles`). The `play` and
`sideload` Android flavors are a build mechanism, not two products.

The launcher shows the app under its own name. Nine optional launcher covers exist, all
disabled by default and opt-in from Settings; see [`docs/guides/disguises.md`](docs/guides/disguises.md).

## Layout

| Path | What lives there |
|---|---|
| `mobile/` | The Flutter app. This is the product. |
| `mobile/lib/core/` | Cross-feature machinery: session, router, theme, crypto, realtime, services, diagnostics. |
| `mobile/lib/features/` | One directory per feature. Screens, controllers and repositories stay together. |
| `mobile/test/` | Unit and widget tests, including the hygiene suite that asserts the repo's shape. |
| `mobile/third_party/flutter_webrtc/` | The one vendored dependency, patched in one Java file (`Miles patch` markers). Android only. |
| `mobile/tool/` | Release script, dependency audit, icon and art generators, and the two handset checks: `two_phone_chat_check.py` (E2EE both ways, DB as oracle) and `perf_budget.py` (cold start and memory budgets). |
| `supabase/migrations/` | The database, in replay order. The **only** place DDL belongs. |
| `supabase/functions/` | Edge Functions (Deno). |
| `supabase/diagnostics/` | Read-only SQL for investigating a live project. Never applied. |
| `web/` | The hosted legal and safety pages (Vercel project `miles-legal`). Single source for that text. |
| `scripts/` | Asset pipelines (intro film, doorstep films) and the TURN health check. |
| `docs/` | See below. |

## Documentation

- [`docs/REFERENCE.md`](docs/REFERENCE.md) — what every module does. Start here.
- [`docs/guides/BRAIN.md`](docs/guides/BRAIN.md) — the session handoff log. Read its tail before touching anything.
- [`docs/guides/PLAY-RELEASE-RUNBOOK.md`](docs/guides/PLAY-RELEASE-RUNBOOK.md) — the ordered path to a Play release.
- [`docs/guides/THREAT-MODEL.md`](docs/guides/THREAT-MODEL.md) — what the encryption does and does not protect.
- [`docs/guides/DEVICE-CHECKLIST.md`](docs/guides/DEVICE-CHECKLIST.md) — what only a handset can verify.
- [`docs/guides/design-system.md`](docs/guides/design-system.md), [`docs/guides/ART-PROMPTS.md`](docs/guides/ART-PROMPTS.md) — look and assets.
- [`docs/FIELD-TEST.md`](docs/FIELD-TEST.md) — how to run a two-phone test and read the trace.
- [`docs/archive/`](docs/archive/) — superseded audits, plans and specs. Kept for history; do not treat as current.

## Build

```bash
cd mobile
flutter pub get
flutter analyze
flutter test
bash tool/release.sh --play      # gates + Play AAB
bash tool/release.sh --bump      # gates + sideload APK
```

`cd mobile` first: running `flutter` from the repo root fails with "No pubspec.yaml". Use
`tool/release.sh` rather than a bare `flutter build`; a bare release build enters the play
graph without the play signing config.

The `play` flavor is signed with the release upload keystore (`mobile/tool/make-keystore.sh`
makes it; it is never committed). The `sideload` flavor is debug-signed for private
distribution. A phone will not upgrade in place across signing keys.

## Configuration

`mobile/.env` is required and never committed. See [`mobile/.env.example`](mobile/.env.example)
for the keys.

Per-environment server values (the Edge Function base URL, the Cloudflare TURN credentials,
the Mapbox token) live in the `app_secrets` table, one row per Supabase project, never in the
repo and never in the APK.

## Working rules

These are assertions, not intentions. `flutter test` fails if any of them breaks.

`test/unit/hygiene/repo_hygiene_test.dart`:

- **No dead code.** Every file under `lib/` is imported by another, every dependency is
  imported, and the analyzer reports zero errors and zero warnings (unused private members
  are warnings here).
- **No commented-out code.** Git remembers it.
- **Suppressions stay countable.** `// ignore:` is bounded, so keeping a warning stays a decision.
- **The repository root holds only `README.md` and `.gitignore`.** Docs are filed under
  `docs/guides/` or `docs/archive/`.

`test/unit/hygiene/migrations_hygiene_test.dart`: DDL only in `supabase/migrations/`, unique
14-digit ordering prefix, every table the client queries created by a migration.

`test/unit/hygiene/schema_drift_test.dart`: every column the client writes exists in
`supabase/schema_snapshot.json`, which is regenerated from the live project.

`test/unit/hygiene/asset_hygiene_test.dart`: every shipped asset is referenced, every
referenced asset ships, and each asset directory has a size ceiling.

And one rule no test can check: **comments explain why.** A comment restating the next line
is noise; a comment naming the failure that line prevents is the most valuable thing in the file.
