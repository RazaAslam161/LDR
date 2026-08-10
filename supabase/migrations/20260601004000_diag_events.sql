-- ───────────────────────────────────────────────────────────────────────────
-- Miles — field diagnostics.
--
-- Calls, receipts and presence have each been "fixed" several times and are
-- each still reported broken. Every diagnosis so far was made from one side of
-- a two-sided failure: two phones, two cities, two carriers, and a debugPrint
-- that only ever reached whichever handset had a cable in it. One theory that
-- survived two months of that was disproved in a single terminal session.
--
-- This table is the missing half. Both devices write to it, so both traces land
-- on one timeline and can be joined by `corr` — the call id, the message id,
-- the couple id. `at` is the device clock already corrected by the client's
-- server-clock offset; `received_at` is Postgres' own now(), kept as the
-- independent check on that correction. When the two disagree, the correction
-- is the bug.
--
-- NO CONTENT REACHES THIS TABLE. The client redacts before it sends (see
-- DiagRedact) and test/unit/diag_privacy_test.dart checks the call sites. What
-- lands here is enums, counts, lengths, durations, and ids that were already
-- random UUIDs — never message text, media paths, coordinates, names or SDP.
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.diag_events (
  id          bigserial primary key,
  couple_id   uuid not null references public.couples(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  -- One app run. Two session ids from one device inside one call means the app
  -- restarted mid-call, which is itself an answer.
  session_id  uuid not null,
  -- Monotonic within a session. ICE fires bursts inside a single millisecond
  -- and their ORDER is the evidence, so a timestamp alone cannot sort them.
  seq         integer not null,
  at          timestamptz not null,
  received_at timestamptz not null default now(),
  area        text not null check (area in ('call', 'receipt', 'presence', 'app')),
  name        text not null,
  corr        text,
  fields      jsonb not null default '{}'::jsonb
);

-- Reading a trace means "this couple, newest first" or "everything about this
-- one call". Those are the only two access patterns; there are no others worth
-- an index on a table this write-heavy.
create index if not exists diag_events_couple_id_idx
  on public.diag_events (couple_id, id desc);
create index if not exists diag_events_corr_idx
  on public.diag_events (corr, seq) where corr is not null;

alter table public.diag_events enable row level security;

-- Insert only your own rows, only into your own couple. Both halves matter: the
-- first stops one partner forging the other's trace, the second stops a signed
-- up stranger writing into a couple they are not in.
drop policy if exists "diag_insert_own" on public.diag_events;
create policy "diag_insert_own" on public.diag_events
  for insert with check (
    user_id = auth.uid()
    and couple_id = public.current_user_couple_id()
  );

-- Both partners can read the couple's trace. This is the point: a call fails
-- because of what happened on the OTHER phone, and that phone is 1,000km away.
-- Safe only because no content is ever written here.
drop policy if exists "diag_read_couple" on public.diag_events;
create policy "diag_read_couple" on public.diag_events
  for select using (couple_id = public.current_user_couple_id());

-- Deliberately no update and no delete policy. A trace that can be edited is
-- not evidence, and RLS denies what it does not permit.
--
-- The grants go further than the policies because RLS DOES NOT APPLY TO
-- TRUNCATE. Supabase's stock setup grants ALL on every public table to anon and
-- authenticated and relies on RLS, which is sound for select/insert/update/
-- delete and silent about the one verb that empties a table outright. It is not
-- reachable through PostgREST today, so this is depth rather than a hole — but
-- the entire worth of this table is that it cannot be rewritten by whoever is
-- being investigated, and that is exactly the property a leftover default
-- should not be trusted with.
revoke update, delete, truncate, trigger, references
  on public.diag_events from authenticated, anon;

-- ── Retention ──────────────────────────────────────────────────────────────
-- A trace is worth nothing after the bug is found and costs storage forever if
-- nobody deletes it. Seven days covers "it happened last weekend, look at it on
-- Monday" and nothing longer is ever used.
create or replace function public.prune_diag_events()
returns void language sql security definer set search_path = public as $fn$
  delete from public.diag_events where received_at < now() - interval '7 days';
$fn$;

do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- unschedule RAISES when the job is absent, so on a database that has never
    -- run this file an unguarded call aborts before schedule() is reached.
    if exists (select 1 from cron.job where jobname = 'prune-diag-events') then
      perform cron.unschedule('prune-diag-events');
    end if;
    perform cron.schedule(
      'prune-diag-events',
      '17 4 * * *',
      'select public.prune_diag_events()'
    );
  end if;
end $do$;
