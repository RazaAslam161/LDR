-- Eight indexes this repo already defines, absent from production — plus the
-- one the message rate limiter has always needed.
--
-- WHY THEY ARE MISSING, which is the actual defect. Every one of them is
-- written `create index if not exists` inside a migration the ledger records
-- as APPLIED (20260601002220, ...2230, ...2250 among them). A migration is
-- never re-run once its version is in supabase_migrations.schema_migrations,
-- so index DDL appended to an already-applied file lands in git and nowhere
-- else. `if not exists` then guarantees the silence: re-running by hand is a
-- no-op-looking success. Verified 2026-09-05 by left-joining all 85 repo index
-- names against pg_indexes on production.
--
-- The two repo names NOT here (memory_couple_state_idx, memory_threads_live_idx)
-- are absent on purpose — a later migration drops each of them.
--
-- Additive only: nothing is renamed, dropped or retyped, so every deployed
-- client keeps reading the same shapes. Re-runnable: `if not exists` makes a
-- second run a no-op.
--
-- ROLLBACK (safe at any time — an index is not data):
--   drop index if exists public.afterglow_active_timeline_idx;
--   drop index if exists public.afterglow_one_pending_per_couple;
--   drop index if exists public.call_signals_couple_created_idx;
--   drop index if exists public.care_nudges_couple_created_idx;
--   drop index if exists public.cycle_events_user_date_idx;
--   drop index if exists public.cycle_logs_user_start_idx;
--   drop index if exists public.love_reasons_couple_created_idx;
--   drop index if exists public.rituals_active_delivery_idx;
--   drop index if exists public.messages_sender_created_idx;

-- Verbatim from the migrations that defined them, so the repo and production
-- agree on the definition and not merely on the name.

create index if not exists afterglow_active_timeline_idx
  on public.afterglow_entries(couple_id, happened_at desc)
  where deleted = false;

-- UNIQUE. Checked against live data first: zero couples hold more than one
-- unsealed afterglow row, so this builds rather than failing on a duplicate.
-- Until now the "one pending per couple" rule was enforced by nothing.
create unique index if not exists afterglow_one_pending_per_couple
  on public.afterglow_entries (couple_id)
  where sealed_at is null;

create index if not exists call_signals_couple_created_idx
  on public.call_signals (couple_id, created_at desc);

create index if not exists care_nudges_couple_created_idx
  on public.care_nudges (couple_id, created_at desc);

create index if not exists cycle_events_user_date_idx
  on public.cycle_events (user_id, event_date desc);

create index if not exists cycle_logs_user_start_idx
  on public.cycle_logs (user_id, period_start desc);

create index if not exists love_reasons_couple_created_idx
  on public.love_reasons (couple_id, created_at desc);

create index if not exists rituals_active_delivery_idx
  on public.rituals(couple_id, deliver_at)
  where deleted = false;

-- The send rate limiter, which has never had an index behind it.
--
-- enforce_send_rate fires BEFORE INSERT on messages and calls
-- send_next_allowed_at, whose body is:
--
--   select greatest(
--     (select max(created_at) from messages where sender_id = $1) + $2,
--     (select created_at from messages where sender_id = $1
--       order by created_at desc offset $3 limit 1) + $4)
--
-- Both halves filter on sender_id and order by created_at. The only covering
-- index was btree(sender_id) alone, so the second half had to read every row
-- the sender has ever written and SORT it — on every message sent, forever.
-- `explain (analyze)` on production returns `Seq Scan on messages` + `Sort`
-- today; at 9 rows that particular scan choice is a small-table artifact, but
-- the sort is not — it is structural and no row count removes it.
--
-- DESC to match the order the query asks for, so the offset walk is a plain
-- backward index scan with no sort node at all.
create index if not exists messages_sender_created_idx
  on public.messages (sender_id, created_at desc);
