-- ───────────────────────────────────────────────────────────────────────────
-- Miles — the app has never been able to say that it is broken.
--
-- FlutterError.onError and PlatformDispatcher.onError debugPrinted and stopped
-- there (main.dart:44-51). The other reporting path, Diag, has been a no-op
-- since build 10 — `if (!_enabled) return` over a flag only resetForTest ever
-- set — so all 75 record/span sites wrote nothing, realtime's CHANNEL_ERROR and
-- the push-received receipt included. There is no crash reporter in pubspec,
-- there is no store console because the app is sideloaded, and there is no
-- support channel because nothing may name the product. A build that crashes on
-- launch for every user looks exactly like a build nobody opened.
--
-- WHAT MAY BE IN A ROW, AND WHY THE LIST IS THAT SHORT
--
-- The writer is a client holding a couple's plaintext, and an error report is
-- the classic way plaintext escapes an end-to-end encrypted app:
-- `StateError('no key for ${m.body}')` is one keystroke and ships a private
-- message inside a crash report. So the exception's message is not sanitised on
-- the way in, it is discarded on the device (ErrorReporter._detail), and three
-- things are sent:
--   error_type  the runtime type. A compile-time symbol; nothing can be
--               interpolated into it.
--   detail      a machine code read from a typed field — Postgrest's SQLSTATE,
--               an auth error code, an errno. Never free text, never parsed out
--               of a message.
--   stack       Dart frames: package, file, line, symbol. The code's identity,
--               never the user's.
-- Cleaning the message instead is the denylist that already lost here once, to
-- a 55-character sentence. That argument is written out at diag_event.dart:86.
--
-- WHY THIS IS NOT AN EXFILTRATION OR SPAM CHANNEL
--   * No select policy for any client role. RLS denies what it does not permit,
--     so a client can write here and can never read back — which is what stops
--     two accounts using it as a mailbox.
--   * user_id is defaulted from auth.uid() and pinned there by the insert
--     policy, so a row cannot be attributed to somebody else.
--   * Every text column has a length ceiling in the schema. One row cannot be a
--     megabyte.
--   * Ten rows per user per hour, in a trigger. A crash loop is the normal case
--     here, not the adversarial one: a widget that throws in build() throws on
--     every frame.
--   * A row cap underneath the age policy. Retention by age alone assumes
--     tomorrow's volume resembles today's; diag_events reached 65% of a 500 MB
--     project on exactly that assumption, and every table in the project goes
--     read-only when the ceiling is hit (20260601005600).
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.client_errors (
  id          bigserial primary key,
  -- User-scoped, not couple-scoped. A crash belongs to a build and a handset,
  -- not to a relationship — and couple scoping would route the insert through
  -- current_user_couple_id(), which is precisely what has not resolved when the
  -- session is the thing that broke. diag.dart:196-201 records that failure
  -- happening to the trace that was meant to explain it.
  --
  -- Defaulted rather than sent, so the client never names itself and therefore
  -- cannot name anyone else. auth.users rather than profiles because a crash
  -- during onboarding, before a profile row exists, is one worth having.
  user_id     uuid not null default auth.uid()
                references auth.users(id) on delete cascade,
  received_at timestamptz not null default now(),
  -- Sideloading means several builds are always live at once, so "it crashes"
  -- without this is unactionable.
  build       integer not null check (build > 0),
  kind        text not null check (kind in ('flutter', 'platform')),
  error_type  text not null check (length(error_type) between 1 and 64),
  detail      text check (length(detail) <= 64),
  stack       text check (length(stack) <= 2000)
);

comment on table public.client_errors is
  'Crash reports. Write-only for clients, read by service_role. Carries an '
  'exception type, a machine code and a stack — never message text, media, or '
  'any other plaintext.';

-- The only question asked on the hot path: how many rows has this user written
-- in the last hour.
create index if not exists client_errors_user_at_idx
  on public.client_errors (user_id, received_at desc);

alter table public.client_errors enable row level security;

drop policy if exists client_errors_insert_own on public.client_errors;
create policy client_errors_insert_own on public.client_errors
  for insert to authenticated
  with check (user_id = (select auth.uid()));

-- Deliberately no select, update or delete policy, for anyone.

-- Two layers rather than one. A table created without this carries Supabase's
-- stock arwdDxtm for anon and authenticated, leaving RLS as the only thing
-- between a probe and the rows — the ops_job_runs finding (20260601005850:40).
revoke all on public.client_errors from anon, authenticated;
grant insert on public.client_errors to authenticated;
-- bigserial, so the id default calls nextval and the insert needs the sequence
-- as well as the table. Without this every insert fails on a permission error
-- the client swallows by design, and the table stays empty while looking
-- correctly configured.
revoke all on sequence public.client_errors_id_seq from anon, authenticated;
grant usage on sequence public.client_errors_id_seq to authenticated;

-- ── Rate limit ─────────────────────────────────────────────────────────────
-- The client already caps itself at five reports a run and drops repeats, but a
-- client-side cap is a request rather than a bound: whoever holds an access
-- token decides what to send.
--
-- Excess rows are dropped silently rather than raised. The caller is an error
-- handler; the only thing it could do with a raised error is throw it away, and
-- a failed insert costs the same round trip as an accepted one.
create or replace function public.client_errors_rate_limit()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  -- True once a tenth row already exists in the window, so ten an hour land and
  -- the eleventh does not.
  if exists (
    select 1 from public.client_errors
     where user_id = new.user_id
       and received_at > now() - interval '1 hour'
    offset 9
  ) then
    return null;
  end if;
  return new;
end $fn$;
revoke execute on function public.client_errors_rate_limit()
  from public, anon, authenticated;

drop trigger if exists client_errors_rate_limit on public.client_errors;
create trigger client_errors_rate_limit
  before insert on public.client_errors
  for each row execute function public.client_errors_rate_limit();

-- ── Retention ──────────────────────────────────────────────────────────────
-- Fourteen days, so a crash can be read against the build before it, with a row
-- cap underneath so the policy is a bound and not a forecast.
create or replace function public.prune_client_errors()
returns void language plpgsql security definer set search_path = public as $fn$
declare
  -- ~2.3 kB a row with every text column at its ceiling, so this is under 50 MB
  -- in the worst case rather than the typical one.
  max_rows constant integer := 20000;
  cutoff_id bigint;
  remaining bigint;
begin
  delete from public.client_errors
   where received_at < now() - interval '14 days';

  -- By row count and not by pg_total_relation_size: bytes do not fall until
  -- autovacuum runs, so a size-driven loop deletes against a number that cannot
  -- drop and empties the table.
  select id into cutoff_id
    from public.client_errors order by id desc offset max_rows limit 1;
  if cutoff_id is not null then
    delete from public.client_errors where id < cutoff_id;
  end if;

  select count(*) into remaining from public.client_errors;
  perform public.ops_record_job(
    'prune-client-errors',
    remaining || ' rows retained' ||
      case when cutoff_id is not null then ' (row cap enforced)' else '' end
  );
end $fn$;
revoke execute on function public.prune_client_errors()
  from public, anon, authenticated;

-- Hourly, alongside prune-diag-events. A bound is worth what its frequency is:
-- once a day leaves a 24-hour window in which the table grows unchecked, which
-- is the window that was the problem last time.
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    -- unschedule RAISES when the job is absent, so on a database that has never
    -- run this file an unguarded call aborts before schedule() is reached.
    if exists (select 1 from cron.job where jobname = 'prune-client-errors') then
      perform cron.unschedule('prune-client-errors');
    end if;
    perform cron.schedule('prune-client-errors', '23 * * * *',
      'select public.prune_client_errors()'
    );
  end if;
end $do$;
