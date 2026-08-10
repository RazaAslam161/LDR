# Migrations — the single source of truth for the database

Everything the database is must be reproducible from this directory. If it is
not in here, it does not exist as far as review, staging, rollback and disaster
recovery are concerned.

## Why this exists

Before this, 42 loose `.sql` files were pasted into the dashboard by hand, in an
order that lived only in header comments. The consequences, all of which
actually happened:

- Columns the client writes existed in **no** file (`profiles.gender`,
  `profiles.gender_set`, `presence.chat_last_read`) — so a brand-new user on a
  clean database hit a permanent dead end at `/role-setup`.
- `hardening_2026_08.sql` reported *"Success. No rows returned"* while three of
  its six protections were **silent no-ops** — a column-level `REVOKE` cannot
  narrow a table-level grant, and a `SECURITY DEFINER` trigger can never see
  `current_user = 'authenticated'`.
- There was no way to answer *"is this fix live?"* except by querying production
  and reading the result.

## The rules

1. **Ordering is the filename.** Files replay in lexical order. The 14-digit
   prefix is an ordering key, not a claim about when it was written.
2. **Append only.** Never edit an applied migration — write a new one. An edited
   migration replays differently on a fresh database than it did on production,
   which is the drift this directory exists to prevent.
3. **Idempotent where practical.** `if not exists`, `create or replace`,
   `drop ... if exists` first. Several of these were re-run by hand during
   incident response and must tolerate it.
4. **DDL only.** Diagnostics and one-off queries live in `../diagnostics/` and
   are never applied.
5. **A migration that changes `public.profiles` columns must re-run the
   column-grant block.** `hardening_2026_08.sql` computes the grant list from
   `information_schema` *at apply time* and `pg_dump` freezes the result, so the
   next `ADD COLUMN` produces a column `authenticated` cannot `UPDATE`. This has
   already caused one production dead end. See the CI check.

## Baselining an existing production database

This directory was reconstructed from the loose files, so production already has
everything in it applied. Tell Supabase that, rather than replaying:

```bash
supabase link --project-ref sopictusdonlvuezmfep
supabase migration repair --status applied 20260601000100 ... 20260601003700
```

**Do the staging replay first.** Order matters and is not negotiable:

1. `supabase db reset` locally — proves the directory replays from empty.
2. Replay onto a scratch project — proves it replays against real Supabase.
3. Only then `migration repair` against production.

Repairing production before a clean replay is proven means the append-only rule
above locks in a baseline that cannot be replayed, and the first person to need
a rebuild discovers it then.

## What is NOT captured here, and must be checked separately

`supabase db diff` compares **schema**. These are **data or dashboard settings**
and will drift silently:

- `storage.buckets.public` — whether a bucket is world-readable
- `cron.job` — whether the scheduled jobs exist and are enabled
- Auth settings (redirect URLs, leaked-password protection)
- `app_secrets` rows (Cloudflare TURN credentials)
- Edge function deployments — `functions/` is the source, but nothing proves the
  deployed version matches it

`../diagnostics/verify_applied.sql` covers part of this today. The architecture
plan (`docs/architecture/revised/data.md`) specifies a `conformance_check()` that
re-derives all of it every 60 seconds; until that ships, run `verify_applied.sql`
after any dashboard change.
