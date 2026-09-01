# Data, schema and operations — migration discipline, environments, RLS shape, indexing, retention, backup/restore, observability, account lifecycle

## Current design
HOW IT WORKS TODAY, PRECISELY (all claims verified against the repo, commands and outputs below).

Schema is 42 loose .sql files in `E:/LDR/supabase/`, applied by hand in the Supabase dashboard SQL editor. Verified: `test -d supabase/migrations` -> NO; `test -f supabase/config.toml` -> NO; `ls .github/workflows` -> "no .github/workflows". `supabase/.temp/linked-project.json` pins one project: `{"ref":"sopictusdonlvuezmfep","name":"LDR"}`. There is one environment. There is no CI.

Later files patch earlier ones rather than superseding them (`hardening_2026_08.sql`, `hardening_couple_id_fix.sql`, `newuser_fixes.sql`), so the true schema is the union of 42 files applied in an order recorded nowhere machine-readable. Every file is wrapped in `if not exists` / `do $$ ... end $$` guards precisely because it gets re-run by hand — which makes each file's effect order-dependent in a way nothing records. The worst instance is the grant-rebuild idiom, which appears three times (`hardening_2026_08.sql:43-45`, `hardening_couple_id_fix.sql:40-42`, `newuser_fixes.sql:170-172`): it does `revoke update on public.profiles from authenticated` then re-grants a column list computed from `information_schema` AT APPLY TIME. Run it before a column exists and that column is silently missing from the grant forever. `newuser_fixes.sql:142-173` documents this trap in its own comments — it is why 100% of new users get stuck on /role-setup on any deploy where the files landed in the wrong order.

SCHEMA DRIFT — MEASURED. The client touches 35 distinct tables (`grep -rhoE "\.from\('[a-z_]+'\)" mobile/lib | sort -u`: afterglow_entries, body_map_pins, body_touches, breath_events, call_invites, capsule_items, capsules, care_nudges, chat_receipts, couples, cycle_events, cycle_settings, daily_prompts, desire_temps, dice_rolls, dice_tier_consents, fantasy_jar_entries, intimacy_prefs, intimacy_signals, love_reasons, memory_revisits, memory_threads, messages, pairing_invites, partner_keys, personal_vault_items, presence, profiles, prompt_responses, reach_events, rituals, vault_items, visits, + 2 storage buckets). Tables with NO `create table` in any repo file: care_nudges, cycle_settings, cycle_events, love_reasons, app_secrets. Columns the client writes that appear in ZERO .sql file: `reply_to_id`, `chat_theme_id`, `chat_bg_image_url`. Buckets with no DDL: couple_media, couple_intimate, chat-bg (only capsule-media is created, `capsules.sql:110`). cycle_events/cycle_settings hold menstrual-cycle history: the app's most sensitive data has no reviewable RLS anywhere in source control.

RLS — TWO MEASURED DEFECTS. (1) Role scoping: `grep -i -A4 "create policy" *.sql | grep -ic "to authenticated"` returns 3, and all 3 are the storage.objects policies in `capsules.sql:113,116,119`. Every one of the ~60 couple-scoped table policies has no role list, so it is attached to `public` and evaluated for anon as well as authenticated. (2) InitPlan caching: `grep -c "(select auth.uid())\|(select public.current_user_couple_id())" *.sql` returns NONE across the whole repo. Every policy calls `public.current_user_couple_id()` or `auth.uid()` unwrapped, so Postgres re-evaluates it per row instead of hoisting it to a once-per-statement InitPlan. `current_user_couple_id()` (`schema.sql:105-113`) is `select couple_id from public.profiles where id = auth.uid()` — STABLE SECURITY DEFINER — so an unwrapped call is a profiles lookup per row.

INDEXING. `profiles(couple_id)` and `presence(couple_id)` do not exist in any file. Those are the two hottest predicates in the app: `presence_select_couple` filters on couple_id (`presence_and_mood.sql:33`), `profiles_select_self_or_partner` filters on couple_id (`schema.sql:119`), `fetchPartner` runs `eq couple_id, neq user_id, order updated_at desc, limit 1` and per inventory/realtime.md fires 4x/min per user from an unconditional poll, and `loadProfile` does a partner lookup on every token refresh and every app resume (inventory/auth.md). Result: an unindexed sequential scan, under a per-row function call, on the app's busiest path — and per inventory/realtime.md the same policy is ALSO evaluated once per subscriber per WAL row by `realtime.apply_rls`.

POLICY SHAPE. Several tables use `FOR ALL USING (...)` with no WITH CHECK — e.g. `20260627_call_invites.sql:26`. Postgres reuses USING as WITH CHECK when absent, so a couple member can INSERT a call_invites row naming arbitrary caller_id and callee_id.

RETENTION. Exactly two cron jobs exist (`grep -rn "cron.schedule" *.sql`): `breath_events.sql:37` (nightly, 1 day) and `reach_pulses.sql:34` — for a table with zero client code, i.e. dead. Nothing purges: messages, call_invites (permanent multi-KB SDP blobs, `answered_at` declared and never written), presence, reach_events, care_nudges, intimacy_signals, `net._http_response`, `cron.job_run_details` (Supabase documents no retention for it — research/supabase.md:149 — so it grows forever on a 500 MB database), vault_items where retention='ephemeral' and reconfirm_due has passed, orphaned chat-bg uploads, flung GIFs, touch reaction images. Dissolved couples: `couples.active=false` is written and read by nothing (inventory/auth.md), so dead couples and every row they own accumulate permanently.

OBSERVABILITY. The entire monitoring layer is five hand-run files: diagnose_all.sql, diagnose_couple.sql, diagnose_presence.sql, diagnose_presence_delivery.sql, verify_applied.sql. Failures vanish in four verified places: pg_net is fire-and-forget with responses GC'd after 6 h and no documented retry (research/supabase.md:147) and carries every push in the app (`net.http_post` in fcm_push.sql, message_push.sql, 20260628_care_call_push.sql x2); `reach-notify` returns HTTP 200 on every error path so the invocation metric reads 100% healthy during a total delivery outage (inventory/calls.md, chat.md); client `catch (_) {}` swallows text-send failures entirely (inventory/chat.md calls it "silent permanent data loss"); pg_cron failures surface only if something queries cron.job_run_details, and nothing does.

BACKUP/DR. Free tier: daily logical backup, 7-day retention, no PITR. But since the repo cannot rebuild the database, restoring data into a fresh project is not possible either — you would restore rows into a schema you cannot reproduce. Nobody has ever tested a restore.

ENVIRONMENT COUPLING. `20260628_care_call_push.sql` posts to the literal `https://sopictusdonlvuezmfep.supabase.co/functions/v1/reach-notify` inside the trigger body. A byte-perfect copy of this schema in a second project sends its push notifications to production users' phones.

SQL TEST COVERAGE IS ZERO. `mobile/test/unit` holds 20 test files; all are Dart-level (receipts_v2_test.dart tests the Dart model, not the RPC). No test anywhere executes SQL. Flagged as a gap, not implied coverage.

WHY IT FAILS AT SCALE. Not throughput — reproducibility. There is no staging, so no fix can be tested anywhere except production with two phones, which is exactly the evidence standard that has passed and then failed repeatedly. There is no reviewable RLS change, no rollback, no restore. The RLS shape multiplies three documented penalties (research/supabase.md:310: unindexed policy column 171 ms -> <0.1 ms; unwrapped auth call 179 ms -> 9 ms and 178,000 ms -> 12 ms; missing TO authenticated 170 ms -> <0.1 ms) and pays them twice: once per PostgREST query and once per subscriber per WAL row. And the first hard wall is not traffic at all — Closer stores full-resolution photos as `bytea` in Postgres (inventory/closer.md: imageQuality 85, no maxWidth) against a 500 MB Free-tier database.

## Target architecture
THE ONE MECHANISM: the database has exactly one source of truth — `supabase/migrations/` — and a CI job that fails when the deployed database differs from what the repo produces. Staging, reviewable RLS, rollback, DR and schema-drift detection are all consequences of that single property, not separate projects.

1. MIGRATION DISCIPLINE
Committed: `supabase/config.toml`, `supabase/migrations/<timestamp>_<name>.sql`, `supabase/seed.sql`.
The baseline is CAPTURED, NOT RECONSTRUCTED: `supabase db dump --schema public,storage,auth` from production becomes `00000000000000_baseline.sql`, then `supabase migration repair --status applied 00000000000000` marks prod's ledger without executing anything against it. The 42 historical files move to `docs/history/sql-archive/` marked do-not-run. This deletes the 42-file ordering problem rather than solving it, and it captures the 5 undefined tables and 3 undefined columns exactly as they really are.
Rules: migrations are append-only, never edited after applying, and carry no `if not exists` guards — the ledger (`supabase_migrations.schema_migrations`) records what ran, so a migration that would be a no-op on re-run is a migration whose effect you cannot verify.
CI on every PR: `supabase db start` -> apply all migrations to an empty Postgres -> apply seed -> run SQL assertions -> `supabase db diff --linked` against staging must be empty -> `supabase db lint`. Nightly: `supabase db diff --linked` against PRODUCTION, fail loudly on non-empty. That nightly job is the only thing that catches the actual historical failure mode (dashboard hand-edits).

2. ENVIRONMENTS
local (docker) / staging (own Supabase project, Free) / prod. `seed.sql` creates 2 couples, 4 users, ~50 messages, presence rows, a call invite — deterministic UUIDs so assertions can name them.
No environment-specific literal may appear in a migration. The hardcoded project ref in `notify_call`/`notify_reach`/`notify_message`/`notify_care` becomes `current_setting('app.functions_base_url', true)`, set per-database via `ALTER DATABASE ... SET`. A CI grep fails the build on any project ref, `https://` host, or key-shaped literal under `supabase/migrations/`.

3. THE RLS PATTERN
One shape, applied mechanically to every couple-scoped table, four policies each with USING and WITH CHECK stated separately:
  create policy "<t>_select_member" on public.<t>
    for select to authenticated
    using ( couple_id = (select public.current_user_couple_id()) );
Three changes, each with a documented measurement (research/supabase.md:310): `TO authenticated` means the policy is not evaluated at all for anon/service roles (170 ms -> <0.1 ms); `(select fn())` hoists the call to an InitPlan evaluated once per statement instead of once per row (179 ms -> 9 ms, and 178,000 ms -> 12 ms on a complex policy); the index on the predicate column (171 ms -> <0.1 ms). `current_user_couple_id()` stays SECURITY DEFINER STABLE (11,000 ms -> 7 ms for exactly this join-avoidance pattern) and gains `parallel safe`.
`FOR ALL USING (...)` with no WITH CHECK is banned — it is how call_invites currently lets a member insert a row naming an arbitrary caller_id/callee_id.
Enforcement is a catalogue query, not a reviewer: assert over `pg_policies` that `roles <> '{public}'`, that `qual`/`with_check` contain no bare `auth.uid()` or `current_user_couple_id()` outside a `(select ...)`, and that `with_check is not null` for cmd in (ALL, INSERT, UPDATE). Runs in under a second in CI.

4. INDEXING — ONE INDEX PER NAMED QUERY, ADDED IN THE MIGRATION THAT NEEDS IT
- `profiles(couple_id)` — backs `profiles_select_self_or_partner` and the partner lookup that runs on every token refresh and every app resume. Missing today.
- `presence(couple_id, updated_at desc)` — backs `presence_select_couple` and `fetchPartner`'s `eq couple_id, neq user_id, order updated_at desc, limit 1`, which fires 4x/min/user. Missing today.
- `call_invites(couple_id, created_at desc)` — for lookup and for the retention sweep. Missing today.
- `messages(couple_id, seq)` already exists (receipts_v2.sql:49) and is the right index for the catch-up query; `messages(couple_id, created_at)` exists ASC and Postgres scans it backwards for the `order by created_at desc limit 300` load — leave both alone.
Rule: an index ships with the query that justifies it, and the migration comment names that query. Nothing speculative.

5. RETENTION — DATA, NOT CODE
One table `public.retention_policy(table_name, ts_column, keep_interval, batch_size, enabled)` and ONE pg_cron job `miles_retention` (hourly) that loops the registry doing bounded `delete ... where ts < now() - keep and ctid in (select ctid ... limit batch)` until zero rows or a wall-clock budget. One job, not ten, because Supabase recommends <=8 concurrent jobs and <=10 min each (research/supabase.md:149) — and because a registry entry is an INSERT in a migration, so adding a retention rule is reviewed, diffed and rolled back like any other change.
Initial entries: call_invites 24 h (plus null `offer_sdp` after 10 min — the SDP is worthless after that, it is the bulk of the row, and nulling it is what stops a stale invite being answerable forever); reach_events 7 d; care_nudges 90 d; breath_events 1 d (until breath moves to broadcast, then drop the table); `net._http_response` 6 h explicitly rather than relying on a setting we cannot migrate; `cron.job_run_details` 7 d (mandatory — Supabase documents no retention and it grows forever on a 500 MB database).
NOT swept: messages. Chat history is the product. Partitioning is the eventual answer, deliberately deferred (see scale ceiling).
Storage: an orphan sweep job deletes objects under `<couple_id>/` with no referencing row — flung GIFs, superseded chat-bg uploads, touch reaction images, all documented as permanent leaks.

6. STORAGE AS SCHEMA
Bucket definitions become migrations (`insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) ... on conflict do update`) for all four buckets, and storage.objects policies alongside them.
`couple_media` stops being public. Public bucket + couple_id as the first path segment is why the couple UUID leaks, which is why every unauthenticated broadcast topic in the app is guessable — chat.md, closer.md and calls.md all trace their worst finding back to this one fact.
Closer photos move out of `bytea` into Storage; the columns hold a path. This is both a correctness fix and a cost fix (see cost).

7. ACCOUNT LIFECYCLE — A STATE MACHINE, NOT A STATEMENT
`public.account_deletions(user_id pk, requested_at, state, purge_after, completed_at, error)`. `delete_my_account()` does three fast things and returns: write the request row, delete the user's `auth.sessions` rows (closing the documented hole where the JWT stays cryptographically valid ~1 h after the row is gone), and set `purge_after = requested_at + 7 days`. The retention sweeper does the physical purge in bounded batches — retryable and countable, instead of one unbatched multi-table + storage delete inside a request transaction with `exception when others then null` around the storage half.
Revocation is immediate and atomic across every table because it lives in the tenancy helper: `current_user_couple_id()` returns NULL when the caller has a pending deletion request, and NULL when their couple has `dissolved_at` set. Every couple-scoped policy already routes through that function, so ~35 tables go dark on one function change, and a table added tomorrow inherits it without anyone remembering.
`public.data_subject_map(table_name, owner_column, scope)` drives both export and purge, so they cannot disagree. `export_my_data()` is a request row too — the job writes JSON to a private `exports` bucket and returns a signed URL, because the Edge Function CPU limit is 2 s per request (research/supabase.md:145) and a full export will not fit.
Couple dissolution writes `couples.dissolved_at`; a registry entry purges couple-scoped rows 90 days after. Because the helper already returns NULL for a dissolved couple, that purge is storage reclamation, not a privacy race.

8. OBSERVABILITY — MAKE EVERY ASYNC EFFECT COUNTABLE
`public.push_outbox(id, kind, payload jsonb, state, attempts, next_attempt_at, last_error, created_at)`. The four notify triggers INSERT into it instead of calling `net.http_post`. One pg_cron worker (every 10 s) claims a batch `for update skip lock` -> `net.http_post` -> records status. Retry with backoff and a dead-letter state become trivial, and — the point — VISIBLE: `select state, count(*) from push_outbox group by 1` is the health metric. This single table replaces "no retry, no dedupe, no batching, no visibility" (four separate findings across chat.md, calls.md and rest.md) with one mechanism. With the outbox owning retry, `reach-notify` can stop returning 200-on-error and report honestly.
`public.ops_events(ts, kind, severity, couple_id, detail jsonb)` — append-only. Rule: any path that swallows an error writes an ops_event first.
SLIs, all plain SQL, no vendor: push_outbox oldest-pending age and dead-letter count/hour; cron.job_run_details failures in 24 h; retention rows-eligible vs rows-deleted per table (this is the early warning that the sweeper is falling behind); pg_stat_statements top-10 by total_exec_time (where an RLS regression appears); Supabase Realtime reports for connected clients and channel joins/sec (available on all plans, research/supabase.md:320); DB size against the tier limit; storage bytes per bucket. One pg_cron job evaluates them and writes a severity='page' ops_event plus a single push to the owner's device. Do not buy Datadog for two users.

## Invariants
- THE REPO PRODUCES THE DATABASE, OR CI FAILS. `supabase db diff --linked` must be empty against staging on every PR and against production nightly. A column that exists in the database and not in migrations is a build failure, not a 2am surprise. This is the invariant the domain is missing today: 5 tables (care_nudges, cycle_settings, cycle_events, love_reasons, app_secrets) and 3 columns (reply_to_id, chat_theme_id, chat_bg_image_url) that the client writes exist in no .sql file at all.
- A MIGRATION IS APPEND-ONLY AND ITS EFFECT IS OBSERVABLE ON FIRST RUN. Guards (`if not exists`, `do $$ ... end $$`) are forbidden because the ledger already records what ran. A migration that would be a no-op on re-run is a migration whose effect you cannot verify — which is exactly why nobody can say today what order the 42 files were applied in, or what the grant-rebuild in newuser_fixes.sql:170 actually granted.
- NO ENVIRONMENT-SPECIFIC LITERAL EVER APPEARS IN A MIGRATION, ENFORCED BY GREP. CI fails on any occurrence of a project ref, an `https://` host, or a key-shaped string under supabase/migrations/. Today `notify_call` hardcodes `https://sopictusdonlvuezmfep.supabase.co/functions/v1/reach-notify`, so a faithful copy of the schema in staging would ring production users' phones.
- EVERY RLS POLICY IS ROLE-SCOPED, INITPLAN-WRAPPED AND INDEX-BACKED — ASSERTED BY A QUERY OVER pg_policies, NOT BY REVIEW. `roles <> '{public}'`; no bare `auth.uid()` or `current_user_couple_id()` outside a `(select ...)`; an index exists on every column named in a policy predicate. Measured today: exactly 3 policies in the repo carry a role list and all 3 are storage.objects policies in capsules.sql; ZERO policies anywhere use the `(select ...)` wrapper; profiles(couple_id) and presence(couple_id) have no index. A reviewer will not catch this reliably — a catalogue query catches it every time in under a second.
- EVERY POLICY STATES USING AND WITH CHECK SEPARATELY. `FOR ALL USING (...)` alone fails CI, because Postgres silently reuses USING as WITH CHECK — which is precisely how `call_invites` (20260627_call_invites.sql:26) lets a couple member INSERT a row naming an arbitrary caller_id and callee_id. Checkable: `select * from pg_policies where cmd in ('ALL','INSERT','UPDATE') and with_check is null`.
- READABILITY IS REVOKED BY ONE FUNCTION, SO REVOCATION CANNOT BE PARTIALLY APPLIED. `current_user_couple_id()` returns NULL when the caller has a pending account-deletion request or their couple is dissolved. Every couple-scoped policy already routes through it, so ~35 tables go dark atomically on one function change, and a table added next month inherits the behaviour without anyone remembering. Contrast today: leave_couple() nulls 17 presence columns by hand in a specific order because a trigger races it.
- A TABLE HOLDING USER DATA THAT IS ABSENT FROM data_subject_map FAILS CI. Export completeness and deletion completeness are then the same fact and cannot diverge as tables are added. Today the deletion RPC enumerates buckets by hand (account_deletion.sql lists couple_media, couple_intimate, capsule-media) and therefore misses chat-bg entirely.
- RETENTION IS DATA, NOT CODE: ONE REGISTRY TABLE, ONE SWEEPER. A retention rule is an INSERT in a migration — reviewed, diffed, revertible — and the number of cron jobs stays at 1 no matter how many tables exist, which is what keeps the design inside Supabase's documented guidance of <=8 concurrent jobs and <=10 minutes each.
- EVERY SWEEP IS BOUNDED AND IDEMPOTENT: `delete ... where ctid in (select ctid ... limit n)` inside a loop with a wall-clock budget. An unbounded DELETE on a Nano instance with 250 baseline IOPS is an outage; a bounded batch means a killed job resumes rather than rolls back, and a second run deletes zero rows.
- NOTHING OBSERVES SUCCESS BY THE ABSENCE OF AN ERROR. Every asynchronous effect owns a row whose state can be counted: push_outbox is pending|sent|failed|dead, account_deletions is requested|purging|done|error. 'The trigger fired' is not evidence; '0 rows in state=dead' is. Today the only evidence a push happened is a row in net._http_response that Postgres deletes after 6 hours, behind an edge function that returns HTTP 200 on every failure path.
- A DESTRUCTIVE MIGRATION IS PRECEDED BY A PREVIEW THAT RAN FOR AT LEAST 7 DAYS. Any migration deleting user rows ships in two parts: a counting view merged and observed first, then the delete. This is not process theatre — the 'ephemeral' retention sweep will destroy vault and memory-thread content that users were told was saved, and the only safe way to learn how much is to count it before deleting it.

## Why this mirrors the top tier
MIRRORS SUPABASE'S OWN PUBLISHED RLS PERFORMANCE GUIDANCE, WITH ONE DELIBERATE ADDITION. research/supabase.md:310 (sourced from the Supabase RLS performance doc) gives four measured deltas: index the policy column 171 ms -> <0.1 ms; wrap the auth call in a subselect 179 ms -> 9 ms and 178,000 ms -> 12 ms; add `TO authenticated` 170 ms -> <0.1 ms; use a SECURITY DEFINER helper to avoid the join 11,000 ms -> 7 ms. This design applies all four. WHERE IT DIFFERS: Supabase publishes the guidance but not the enforcement. Here the four properties are asserted by a query over `pg_policies` in CI, because the repo's current state is the proof that guidance alone does not hold — zero of ~60 policies are wrapped and three of ~60 are role-scoped, in a codebase whose author clearly knew about RLS (the couple-scoped pattern is applied consistently and correctly for *correctness*).

MIRRORS THE TRANSACTIONAL OUTBOX (Chris Richardson / microservices.io; the same shape as Debezium's outbox router and how Stripe and Shopify handle at-least-once webhook egress). Applied because pg_net has no documented retry, a 2 s default timeout and a 6-hour response TTL (research/supabase.md:147) while carrying every push in the app. The outbox converts fire-and-forget into at-least-once with a countable backlog. WHERE IT DIFFERS: no CDC, no Debezium, no Kafka. At ~2 pushes per message for a two-person tenant, a single table drained by a pg_cron worker using `for update skip locked` is the correct size, and pg_net's documented ~200 req/s ceiling sits three orders of magnitude above the requirement even at 10k users. Importing the full pattern would be cargo cult.

MIRRORS MIGRATION-AS-LEDGER PLUS DRIFT DETECTION (Flyway, Sqitch, Atlas; and the Supabase CLI, which already implements both `supabase_migrations.schema_migrations` and `db diff --linked`). WHERE IT DIFFERS, AND THIS IS THE LOAD-BEARING DIFFERENCE: the baseline is captured from production by `db dump`, not reconstructed from the 42 historical files. Textbook Flyway adoption tells you to write a baseline script. Projects in this exact state die there, because you can never prove the reconstruction is faithful — and here it provably would not be: care_nudges, cycle_settings, cycle_events, love_reasons and app_secrets have no definition to reconstruct from, and cycle_events holds menstrual-cycle history whose RLS nobody can see. `db dump` + `migration repair --status applied` adopts reality in about thirty seconds and executes nothing against production.

MIRRORS SOFT-DELETE-THEN-PURGE WITH IMMEDIATE REVOCATION, the standard GDPR-compliant shape across SaaS, and notably the shape Supabase's own `auth.admin.deleteUser` cannot give you because it is synchronous. WHERE IT DIFFERS: revocation is implemented inside the tenancy helper rather than as a `deleted_at` predicate repeated on every table. That is what makes it atomic across ~35 tables and immune to someone adding table 36.

MIRRORS pg_partman's retention-config-table pattern (one config row per table, one worker). WHERE IT DIFFERS: no pg_partman, and DELETE-in-batches rather than DROP PARTITION, because at this data volume partitioning is structure nobody has earned yet. The trigger condition for switching is stated explicitly rather than left as a someday.

## Scale ceiling
This is an ops/schema domain, so the ceiling is a different kind of number than a throughput domain — but the honest ones are these.

1,000 USERS (~80 peak concurrent). Nothing in this design is load-limited here. The binding constraint is the FREE TIER'S 500 MB DATABASE, and it is a schema decision rather than a traffic problem: Closer stores full-resolution photos as `bytea` in Postgres (inventory/closer.md — ImagePicker imageQuality 85, no maxWidth/maxHeight, on vault_items, memory_threads and afterglow_entries), and PostgREST ships them hex/base64-encoded at roughly 2x on the wire. At ~2 MB per photo, about 250 photos fills the entire free database. FAILURE MODE: writes begin failing and the project goes read-only, but Realtime keeps delivering broadcasts, so the app looks alive while silently discarding every write — the worst possible shape of failure and the hardest to diagnose from a phone. Must-fix before 1k: photos to Storage, columns hold a path. Post-fix, the retention sweeper at this scale processes low thousands of rows/hour, well under 1% of Nano's 250 baseline IOPS.

10,000 USERS. The RLS work pays off here or the app is unusable: the partner-presence SELECT runs ~4x/min/user unconditionally (inventory/realtime.md) = ~667 reads/sec at full concurrency, and today that is a sequential scan on an unindexed column under a per-row function call. With `presence(couple_id, updated_at desc)` and an InitPlan-wrapped predicate it is a single-row index scan. Message rows accrue at roughly 200 bytes x 200 msgs/user/month = ~5 GB/year including indexes; Small-Medium compute handles it. THE REAL CEILING AT THIS SCALE IS THE SWEEPER'S WALL CLOCK: a single-threaded batched delete against a table approaching 10^8 rows will exhaust its budget and fall permanently behind. FAILURE MODE: silent backlog growth, disk filling over weeks, discovered when writes fail. This is why the sweeper must record rows-eligible alongside rows-deleted — if eligible > deleted for 24 h, page. That single measurement is the difference between finding out in a day and finding out in three weeks.

100,000 USERS. `messages` must be partitioned (monthly RANGE on created_at) and the retention job must switch from DELETE to DROP PARTITION; that is the precise point where the batched-delete design stops working. The drift detector's `supabase db diff` also starts taking minutes and must move off the PR path to nightly-only. FAILURE MODE IF PARTITIONING IS SKIPPED: autovacuum cannot keep pace with delete churn, table and index bloat grow, `messages(couple_id, seq)` degrades, and the catch-up query — which runs on every app resume for every user (inventory/chat.md) — goes from ~2 ms to seconds. Symptom: the whole app feels broken, with no error logged anywhere. Beyond this point the ceiling stops being this domain's: it becomes the Realtime message quota (2,500 msg/s hard on Team, research/supabase.md:276) and the Edge Function OAuth path.

THE CEILING ON THE DISCIPLINE ITSELF, STATED HONESTLY. The CI drift check breaks the moment someone edits the database in the dashboard and does not say so. There is no technical prevention available — Supabase does not let you revoke DDL from the project owner. The mitigation is detection, not prevention: the nightly diff surfaces it within 24 hours. This is a residual risk that a policy agreement covers and engineering does not. Given that hand-editing the dashboard is the documented historical behaviour of this project, it is the single most likely way this design decays, and it should be treated as such rather than declared solved.

## Cost
All figures monthly. Supabase list prices per research/supabase.md:307,316,318.

THE WHOLE MIGRATION / ENVIRONMENTS / CI / RETENTION / OBSERVABILITY PROGRAMME COSTS $0 UP TO 1,000 USERS.
- Staging Supabase project: $0 (Free tier). It holds 2 seeded couples and 4 users. This is the most important line in this section — reproducibility is not expensive here, it is free, and the reason it does not exist is not budget.
- CI: GitHub Actions free tier is 2,000 minutes/month. A migration check is `supabase db start` (~60 s) plus apply plus diff, about 2 minutes per PR. At 50 PRs/month that is 100 minutes. $0.
- pg_cron retention sweeper, push_outbox worker, SLI job: they run on your own compute. An hourly bounded sweep of a few thousand rows is under 1% of Nano's 250 baseline IOPS. $0.
- push_outbox storage: ~200 bytes/row at 24 h retention. At 10k users x 200 msgs/user/month = 2 M rows/month, only ~66k alive at any instant, about 13 MB. $0.

DELTAS THAT ARE REAL MONEY:

Making `couple_media` private. Private buckets are checked per-user so they miss the CDN and bill as UNCACHED at $0.09/GB, versus $0.03/GB cached (research/supabase.md:155,318).
- 1k users, ~20 GB/mo media reads: $1.80 vs $0.60 -> delta +$1.20/mo.
- 10k users, ~200 GB: $18.00 vs $6.00 -> delta +$12/mo.
- 100k users, ~2 TB after the 250 GB Pro allowance: (2000-250) x $0.09 = $157.50 vs ~$52 cached -> delta ~+$105/mo.
This closes the root cause of couple_id being guessable, which is what makes every unauthenticated broadcast topic in the app exploitable. It is the right trade at every one of those three numbers.

Moving Closer photos out of `bytea` into Storage. This SAVES money and is the difference between working and not at 1k users. Postgres disk is $0.125/GB-month past the 8 GB Pro allowance; object storage is $0.0213/GB-month past 100 GB — roughly 6x, before counting the base64/hex inflation on every PostgREST read.
- 10k users at ~100 MB vault media each = 1 TB: in Postgres (1000-8) x $0.125 = ~$124/mo (and an unusable database); in Storage (1000-100) x $0.0213 = ~$19/mo. SAVING ~$105/mo at 10k, and at 1k it is the difference between a working app and a read-only one.

PITR. $100/mo add-on on Pro. Daily backups with 7-day retention are included on Pro; Free gets daily backups with no PITR.
- 1k users: DO NOT BUY. $0. PITR protects against a bad write; this app's actual DR gap is that the schema cannot be rebuilt, which PITR does not address at all. Daily backup + reproducible repo + a monthly restore rehearsal is strictly better value at this size.
- 10k users: BUY. +$100/mo. At that point a bad migration costs 10,000 people's history.
- 100k users: +$100/mo.

TOTALS FOR THIS DOMAIN'S SHARE OF THE BILL (against the whole-app figures in research/supabase.md:259,266,273 of ~$58, ~$500-560 and ~$5,000-6,500):
- 1,000 users: +$1.20/mo (private bucket delta), and a ~$0-to-large saving from getting photos out of Postgres depending on how much is already there. Effectively free.
- 10,000 users: +$12 (bucket) +$100 (PITR) +$19 (object storage) = ~+$131, against ~-$105 saved by not holding that media in Postgres. Net ~+$26/mo, plus compute Small-Medium $15-60 which you are paying regardless.
- 100,000 users: +$105 (bucket) +$100 (PITR) +$40 (storage, rising monthly) = ~+$245/mo, against compute Large-XL $110-210 you pay regardless. Partitioning at this scale is engineering time, not money.

The claim that migration discipline is expensive is false for this project. The expensive thing is the current state: an unusable-at-1k-users database because photos are in `bytea`, and a schema nobody can rebuild.

## Migration
Seven stages. Every one is independently shippable and independently revertible. Exactly one step in the entire plan requires a coordinated client release, and it is called out. There is no big bang — and the reason there isn't is Stage 0, which makes the existing production database the baseline instead of the adversary.

STAGE 0 — CAPTURE (1 day, zero risk, nothing executed against prod)
1. `supabase init`, commit `config.toml`.
2. `supabase link`, then `supabase db dump --schema public,storage,auth -f supabase/migrations/00000000000000_baseline.sql`. Separately dump `storage.buckets` rows as a data migration.
3. `supabase migration repair --status applied 00000000000000` — prod's ledger now says the baseline is applied. No DDL runs against production.
4. Move the 42 files to `docs/history/sql-archive/` with a README stating they are historical and must never be run.
VALUE ON ITS OWN: the repo describes the database for the first time, including the 5 tables and 3 columns that have no definition anywhere.

STAGE 1 — STAGING + CI (2 days)
5. Create a second Supabase project (Free). `supabase db push` the baseline into it. If it fails, that failure IS the finding — fix by adding real DDL as migration 0001. This is how care_nudges, cycle_settings, cycle_events, love_reasons and app_secrets acquire reviewable definitions and reviewable RLS.
6. Write `supabase/seed.sql`: 2 couples, 4 users, ~50 messages, presence rows, one call invite, deterministic UUIDs.
7. GitHub Actions. On PR: `supabase db start`, apply migrations, apply seed, run SQL assertions, `supabase db diff --linked` must be empty. Nightly: diff against prod, fail on drift.
VALUE ON ITS OWN: every subsequent change is testable and reviewable without touching a phone.

STAGE 2 — DE-HARDCODE ENVIRONMENTS (half a day) — MUST LAND BEFORE STAGING TAKES ANY TRAFFIC
8. Migration 0002 replaces the literal `https://sopictusdonlvuezmfep.supabase.co/functions/v1/reach-notify` in `notify_call`, `notify_reach`, `notify_message` and `notify_care` with `current_setting('app.functions_base_url', true)`, set per-database. Add the CI grep that fails on any project ref or URL literal under supabase/migrations/.
ORDERING IS LOAD-BEARING: without this, the staging project created in Stage 1 sends push notifications to production users' phones the moment anything inserts a row.

STAGE 3 — RLS CORRECTNESS AND PERFORMANCE SWEEP (2-3 days, one migration per table)
9. Per table: rewrite the four policies to `TO authenticated` + `(select public.current_user_couple_id())` + explicit WITH CHECK. Add the index the policy needs in the SAME migration (`profiles(couple_id)`, `presence(couple_id, updated_at desc)`, `call_invites(couple_id, created_at desc)`).
10. Land the `pg_policies` assertions as WARNINGS first, flip them to hard failures when the non-conforming count reaches zero — otherwise the build is red for every table not yet converted.
ORDER: messages, presence, profiles, chat_receipts first. Those four carry the overwhelming majority of traffic. Each table is its own migration, its own PR, its own revert.

STAGE 4 — PUSH OUTBOX (3 days)
11. Migration: `push_outbox` + states. Change the four notify triggers to INSERT instead of `net.http_post`. Add the pg_cron drain worker. Change `reach-notify` to return real status codes now that retry has an owner.
12. Add the dead-letter SLI and the ops_events alert.
NO CLIENT RELEASE NEEDED — the app behaves identically on the happy path.

STAGE 5 — RETENTION (2 days, deliberately split)
13. `retention_policy` registry + the single sweeper + `cron.job_run_details` cleanup. Enable only the safe entries first: call_invites SDP nulling and 24 h purge, reach_events, care_nudges, net._http_response, cron history.
14. SEPARATELY AND LATER: a `retention_preview` view for the 'ephemeral' Closer content. Merge it, observe for 7 days, then decide (see open decisions). Do not couple this to step 13.

STAGE 6 — STORAGE AS SCHEMA (2 days) — CONTAINS THE ONLY RELEASE-COUPLED STEP
15. Bucket definitions and storage.objects policies as migrations. Orphan sweep job for chat-bg, flung GIFs and touch reaction images.
16. `couple_media` -> private. THIS ONE NEEDS A CLIENT RELEASE AND A WINDOW: every `getPublicUrl` string already stored in the database stops resolving. Staged as release N (client learns to read signed URLs) -> wait for adoption -> release N+1 (flip the bucket), with the old public bucket kept as a fallback for 30 days.

STAGE 7 — ACCOUNT LIFECYCLE (3 days)
17. `data_subject_map` + the CI completeness check comparing it against RLS-enabled tables.
18. `account_deletions` state machine; `delete_my_account()` becomes request + session revoke; purge moves to the sweeper.
19. `current_user_couple_id()` returns NULL for pending deletion and for dissolved couples. ONE FUNCTION CHANGE, ~35 TABLES GO DARK.
20. `export_my_data()` as an async job writing to a private `exports` bucket.
Steps 17-19 ship independently of 20.

DEFERRED, WITH AN EXPLICIT TRIGGER RATHER THAN A "SOMEDAY": partition `messages` monthly and switch the sweeper to DROP PARTITION when the table passes ~50 M rows OR when the sweeper's rows-eligible exceeds rows-deleted for 24 h, whichever comes first.

## Verification
GOVERNING PRINCIPLE: every claim in this domain is verifiable against a Postgres container on one laptop. Nothing here needs a network, a partner, a second device, or a correct clock. That is not a convenience — it is the whole point, because the reason previous fixes passed and then failed is that the only available test was two NTP-synced phones on one wifi.

1. REPRODUCIBILITY. `supabase db start && supabase db reset` applies every migration to an empty database. If it succeeds, the repo builds the database. Today it demonstrably does not — this single command would have caught every "column exists in NO sql file" finding in the inventory, at zero cost, at any point in the last year.

2. DRIFT. `supabase db diff --linked` must print nothing: against staging on every PR, against production nightly. This is the only check that catches the actual historical failure mode, which is someone typing DDL into the dashboard. It surfaces within 24 hours.

3. RLS CORRECTNESS — AS SQL, NOT AS A PHONE TEST. Against the local database with the seed loaded: `set request.jwt.claims` to user A of couple 1, then assert `select count(*) from messages` returns only couple 1's rows and zero of couple 2's. Assert `insert into call_invites (couple_id, caller_id, callee_id, ...)` naming a caller_id that is not the caller is REJECTED — that assertion FAILS against today's schema, which is the proof it is worth writing. Generate one such test per table by looping `data_subject_map`. Runs in under 5 seconds, fully deterministic.

4. RLS PERFORMANCE — MEASURED, NOT FELT. Scale the seed with `generate_series` to ~100k presence rows and ~1 M messages, then `explain (analyze, buffers) select * from presence where couple_id = $1` under an authenticated role. Assert an Index Scan, and assert the policy predicate appears as `InitPlan 1` in the plan output. This is the crux: an unwrapped function call shows up as a per-row `Filter`, and a `(select ...)`-wrapped one shows up exactly once as an InitPlan. The defect the inventory flags is therefore directly readable in EXPLAIN output and greppable in a CI assertion. No production traffic required to prove it.

5. POLICY SHAPE. Pure catalogue queries over `pg_policies`: roles <> '{public}'; no bare `auth.uid()` or `current_user_couple_id()` in qual/with_check outside a `(select ...)`; with_check not null for cmd in (ALL, INSERT, UPDATE). Sub-second.

6. RETENTION. Seed rows with backdated timestamps via `generate_series`, call the sweeper function directly (not via cron), assert exact row counts before and after, assert the batch bound was respected, assert a second run deletes zero (idempotence), and assert the NEGATIVE — a row inside the keep window is still present. Also assert `cron.job_run_details` shrinks.

7. OUTBOX. Point the local edge function at a stub returning 500. Assert rows walk pending -> failed -> retried -> dead with the expected backoff, and that the dead-letter SLI query returns non-zero so the alert would actually fire. Flip the stub to 200 and assert the queue drains. Zero phones, zero FCM, zero Google OAuth.

8. DELETION AND EXPORT. Run `delete_my_account()` as seeded user A, then assert BEFORE the purge job runs: (a) A's `auth.sessions` rows are gone, (b) `current_user_couple_id()` returns NULL for A, (c) every table in `data_subject_map` returns zero rows for A under A's own JWT. That third assertion is the revocation invariant and it is pure SQL. Then run the purge and assert physical absence. Also assert the partner's rows are untouched — the current RPC only deletes shared media when the last member leaves, which contradicts the dialog copy, and this test pins whichever behaviour is chosen.

9. RESTORE REHEARSAL — MONTHLY, AND IT IS THE DR DRILL AND THE MIGRATION TEST IN ONE COMMAND. Restore last night's production backup into a scratch Free project, apply the pending migrations, run the whole suite above. This is the only thing that proves the backup restores at all. Today nobody knows whether it does, because the question has never been asked, and a restore into a schema the repo cannot reproduce would not help anyway. Cost: one Free project and an afternoon.

WHAT THIS DELIBERATELY DOES NOT VERIFY: whether calling, receipts or presence work. Those belong to other domains. The claim made here is narrower and much stronger — that the database the app talks to is the database in the repo, and that its access rules are what they say they are.

FLAGGED GAP, STATED PLAINLY: SQL test coverage today is ZERO. `mobile/test/unit` contains 20 test files and all are Dart-level; `receipts_v2_test.dart` tests the Dart model, not the `ack_read` RPC. Every test described above is new work, and none of it exists.

## Rejected alternatives
HAND-RECONSTRUCT THE BASELINE FROM THE 42 FILES (reorder them, resolve the union, call it migration 0001). Rejected: you cannot prove the reconstruction matches production, and here it provably would not — care_nudges, cycle_settings, cycle_events, love_reasons and app_secrets have no DDL to reconstruct from, so you would be GUESSING at the definition and RLS of menstrual-cycle history. `supabase db dump` gives the truth in thirty seconds. Reconstruction is the specific trap that keeps projects in this state for another year: it feels like the rigorous option and it produces a fiction.

DECLARATIVE SCHEMA (Atlas, or Supabase's `supabase/schemas` declarative mode) INSTEAD OF VERSIONED MIGRATIONS. Genuinely attractive — one file per table, the tool generates the diff. Rejected for now because generated diffs need a reviewer who can spot a destructive one, and the risk profile here (single maintainer, no staging yet, no CI yet) makes an auto-generated `drop column` a live hazard. Revisit after Stage 3. Nothing is wasted by waiting: a migrations directory is a prerequisite for the declarative workflow either way.

JWT CUSTOM CLAIM FOR couple_id INSTEAD OF THE SECURITY DEFINER HELPER. Faster still — zero table reads per statement, and it is what a large multi-tenant SaaS would do. Rejected as the FIRST move for two reasons. It introduces a staleness window on pairing and unpairing, which is precisely the state transition this app already gets wrong (the both-tap-Create deadlock and the silent unilateral dissolve are both documented in inventory/auth.md). And it forfeits the revocation invariant: once a claim is baked into issued tokens you can no longer make 35 tables go dark by editing one function. The InitPlan wrap delivers the same order-of-magnitude win with none of those semantics. Revisit only if `profiles` lookups actually appear in pg_stat_statements' top 10.

PER-TABLE pg_cron RETENTION JOBS. Rejected: Supabase documents a recommendation of no more than 8 concurrent jobs; the app needs retention on ~10 tables today and more later. It also creates N places to forget a table. One registry-driven sweeper is strictly better and turns "add a retention rule" into a reviewable INSERT in a migration.

PARTITION `messages` NOW. Rejected as speculative structure. At 1k users it is a few hundred thousand rows; partitioning buys nothing and costs a rewrite of the catch-up query's plan assumptions. Named instead as a deferred item with an explicit numeric trigger, because pre-committing to WHEN is the genuinely useful half of that decision.

KEEP pg_net DIRECT AND ADD A RETRY CRON OVER `net._http_response`. This is the minimum fix and it was tempting. Rejected because the evidence is deleted after 6 hours by pg_net's own TTL — you cannot retry what you cannot see, and you get no dedupe, no batching and no way to reason about ordering. It also leaves the HTTP call inside the write transaction's commit path. The outbox is more work once and removes the entire class.

BUY PITR IMMEDIATELY ($100/mo). Rejected at 1k users. PITR protects against a bad write. This app's actual DR gap is that the schema cannot be rebuilt, which PITR does not address at all — you would restore rows into a schema nobody can reproduce. Daily backups plus a reproducible repo plus a monthly restore rehearsal is strictly better value at this size. Buy PITR at 10k.

A SEPARATE MIGRATIONS TOOL (Flyway, Sqitch, dbmate). Rejected: the Supabase CLI already implements the ledger and, critically, `db diff --linked`, which is the check that actually matters. Adding a second tool means two sources of truth about what has been applied — the exact disease under treatment.

ROW-LEVEL `deleted_at` FILTERS ON EVERY TABLE FOR ACCOUNT DELETION. Rejected in favour of revoking through the tenancy helper: 35 places to remember versus 1, and every table added afterwards would silently opt out of it.

## Open decisions
1. DO WE TAKE A WINDOW TO MAKE `couple_media` PRIVATE? Every `getPublicUrl` string already persisted in the database stops resolving — presence.checkin_photo_url, profiles.chat_bg_image_url, personal_vault_items.content, and everything consuming messages.image_path. RECOMMENDATION: yes, staged across two releases — ship signed-URL reading first, flip the bucket after adoption passes ~90%, keep a fallback for 30 days. It is the root cause of couple_id being guessable, which is what makes every unauthenticated broadcast topic in the app exploitable, and it costs $1.20/mo at 1k users. This is the owner's call because it is the only user-visible step in the entire plan.

2. DO WE DELETE `retention='ephemeral'` CLOSER CONTENT THAT THE APP PROMISED WOULD EXPIRE AND NEVER DID? Some of these rows are old. The UI has told users both that this content expires and that it is saved. RECOMMENDATION: preview and count for 7 days, then notify in-app, then sweep with a 30-day grace. Do not sweep silently. This is a product and trust decision wearing an engineering costume, and it should be made by whoever owns the product promise.

3. STAGING ON FREE OR PRO? Free is $0 but auto-pauses after ~7 days idle, and when it does, DNS is withdrawn — CI then fails with a confusing "failed host lookup" rather than a clean error. This project has hit that before. RECOMMENDATION: Free, plus a pg_cron heartbeat or a weekly scheduled CI run to keep it warm. Upgrade to Pro ($25) only if pauses cost more than one wasted debugging session.

4. WHO MAY TOUCH THE DASHBOARD SQL EDITOR? There is no technical control — Supabase does not let you revoke DDL from the project owner. RECOMMENDATION: an explicit policy that the SQL editor is SELECT-only, and that a nightly drift-detector firing is treated as a Sev-2. This needs to be an actual agreement, because the entire design rests on it and the documented historical behaviour of this project is the opposite. If that agreement will not hold, say so now and I will design around it differently (accepting drift and re-baselining weekly, which is worse but honest).

5. WHEN DO WE BUY PITR? RECOMMENDATION: at 10,000 users or at the first paying customer, whichever arrives first. $100/mo. Not before — daily backups plus a reproducible repo plus a tested restore covers more of the actual risk at 1k.

6. SHOULD `messages` DELETION BE TOMBSTONE-THEN-SWEEP RATHER THAN HARD DELETE? Today `clear_conversation_everyone()` hard-deletes, and with REPLICA IDENTITY FULL that emits one full-row WAL event per row — a 10,000-message clear is a 10,000-event burst on the partner's socket (inventory/chat.md). RECOMMENDATION: soft-tombstone plus retention sweep, so the clear becomes a batched UPDATE and stays reversible inside a support window. The owner should decide, because "delete means delete" may be a promise the product intends to keep literally.

7. ADOPT THE DECLARATIVE SCHEMA WORKFLOW AFTER STAGE 3? RECOMMENDATION: revisit then, not now. The migrations directory is a prerequisite either way, so deferring costs nothing.
