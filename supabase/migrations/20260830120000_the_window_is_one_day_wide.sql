-- The window is one day wide.
--
-- 20260829120000 built the ceremony as a SCHEDULING LAYER: a 7-day window and
-- a 4mm banner, with both people still living inside the app. In the field it
-- read as nothing happening at all — the tap that is supposed to be the
-- heaviest in the product produced a countdown strip.
--
-- This file makes the ceremony a RITUAL. The window narrows 7 days -> 24 hours,
-- two gates open on timers instead of instantly, accepting becomes a 5-minute
-- last call rather than a second day, and a scheduled job finishes what the
-- two of them started.
--
-- WHAT THIS FILE REVERSES, deliberately and on the owner's ruling:
--
--   20260829120000 said "there is deliberately NO cron ... a scheduled robot
--   never ends a relationship." That law was written to keep a machine from
--   DECIDING. What it actually produced was a ceremony that cannot FINISH: the
--   person who did not start it is held inside someone else's unfinished
--   decision for exactly as long as that person stays away from the app. With
--   a 7-day banner that was a slow leak. With a 24-hour lockout it is a trap.
--
--   The robot decides nothing here. Two humans already decided — one by
--   starting, the other by not answering for a full day — and the job is the
--   only thing present at the deadline to honour it.
--
-- LAWS carried forward from 20260829120000, unchanged and re-asserted below:
--  * The exits are never gated on the ceremony. leave_couple_permanently()
--    and purge_couple() are byte-untouched; leave_couple() keeps its exact
--    behaviour (see the split below) and still never mentions couple_unlink.
--  * Re-link wins until execution: cancel works in ANY state, and is
--    deliberately NOT time-gated on the server (see unlink_cancel).
--  * Accepting can never EXTEND the ceremony: the last look is still clamped
--    to the cooling deadline.
--  * The row dies with the couple by ANY exit.
--
-- NEW LAWS this file adds:
--  * Every gate is anchored to the ceremony's own start on the SERVER clock,
--    never to when a screen was first opened. A partner who first looks 20
--    hours in does not get a fresh 15-minute wait.
--  * Starting is rate-limited. Without a limit, one tap becomes a button that
--    locks the other person out of the shared app on demand, as often as you
--    like. That is coercive-control surface, not a feature.
--  * A ceremony cannot begin with nobody on the other side of it. The sheet
--    already asks; now the server refuses too (the §200 couple-of-one bug).

-- ── The two gates ────────────────────────────────────────────────────────
--
-- Additive and nullable, so a row written by the previous server still reads
-- on the new client and vice versa. The client defaults a null gate to
-- started_at + 15 minutes, which is what the old server would have meant.

alter table public.couple_unlink
  add column if not exists relink_opens_at       timestamptz,
  add column if not exists partner_gate_opens_at timestamptz;

comment on column public.couple_unlink.relink_opens_at is
  'When the initiator''s Re-link button appears. UI ritual only — '
  'unlink_cancel() is deliberately ungated, because cancelling destroys '
  'nothing and a gated cancel would be a control that throws.';
comment on column public.couple_unlink.partner_gate_opens_at is
  'When the partner may agree. Enforced in unlink_accept(), because THAT '
  'direction destroys.';

-- ── The rate-limit ledger ────────────────────────────────────────────────
--
-- Shaped on pairing_attempts (20260601004900) down to its pruning job: an
-- append-only ledger nobody can read, counted by one SECURITY DEFINER caller.

create table if not exists public.unlink_starts (
  couple_id    uuid not null references public.couples(id) on delete cascade,
  initiated_by uuid not null references public.profiles(id) on delete cascade,
  started_at   timestamptz not null default now()
);

create index if not exists unlink_starts_couple_time
  on public.unlink_starts (couple_id, started_at desc);

alter table public.unlink_starts enable row level security;

-- No policy at all: this is a limiter's ledger, not the couple's data. Being
-- able to read it would tell one partner how many times the other has stood
-- at this door, which is nobody's business and is not what it is for.
revoke all on public.unlink_starts from anon, authenticated;

create or replace function public.prune_unlink_starts()
returns void
language sql
security definer
set search_path = public
as $fn$
  delete from public.unlink_starts where started_at < now() - interval '7 days';
$fn$;

revoke execute on function public.prune_unlink_starts()
  from public, anon, authenticated;

-- ── Splitting the work from the identity ─────────────────────────────────
--
-- leave_couple() is auth.uid()-bound, so a scheduled job cannot call it and
-- the header of 20260829120000 rejects an impersonation shim by name — it is
-- right to. The answer is not a shim: it is to separate WHAT dissolving a
-- couple does from WHOSE session asked.
--
-- dissolve_couple(uuid) below is the current body of leave_couple() moved
-- verbatim, v_couple renamed to p_couple, with every comment kept because
-- every one of them records a bug. leave_couple() becomes the identity
-- wrapper. Behaviour through the client is byte-identical; the presence scrub
-- still exists exactly once.

create or replace function public.dissolve_couple(p_couple uuid)
returns void
language plpgsql
security definer
set search_path = public
as $fn$
begin
  if p_couple is null then return; end if;

  -- 1) The photographs, queued while the paths are still readable. Selected
  --    FROM storage.objects rather than inserted blind, so a path that no
  --    longer resolves — or a legacy row still holding a full URL from before
  --    checkin_photo_url stored a path — queues nothing instead of queueing a
  --    name the reaper will never find.
  insert into public.storage_reap (bucket_id, name)
  select o.bucket_id, o.name
    from public.presence p
    join storage.objects o
      on (o.bucket_id = 'couple_intimate' and o.name = p.body_photo_path)
      or (o.bucket_id = 'couple_media'    and o.name = p.checkin_photo_url)
   where p.couple_id = p_couple
  on conflict do nothing;

  -- 2) Both partners' rows, BEFORE the profiles update. The ordering note from
  --    20260601002400 still binds: trg_sync_presence_couple_id nulls
  --    presence.couple_id the instant profiles.couple_id changes, so a scrub
  --    placed after it matches zero rows and silently does nothing.
  --    location_sharing_mode is set rather than nulled because it is NOT NULL,
  --    and 'off' is the only value that does not re-arm sharing on re-pair.
  --    last_seen and user_id are deliberately left alone: they describe the
  --    account that owns the row, not the relationship that ended.
  update public.presence
     set couple_id             = null,
         is_online             = false,
         is_typing             = false,
         typing_in_chat        = false,
         app_last_active_at    = null,
         current_screen        = null,
         current_activity      = null,
         current_mood          = null,
         mood_color            = null,
         mood_updated_at       = null,
         latitude              = null,
         longitude             = null,
         location_accuracy     = null,
         location_label        = null,
         location_sharing_mode = 'off',
         location_updated_at   = null,
         body_photo_path       = null,
         avatar_emoji          = null,
         checkin_photo_url     = null,
         checkin_photo_at      = null,
         chat_last_read        = null,
         updated_at            = now()
   where couple_id = p_couple;

  -- 3) Everything 20260815071024 did, unchanged.
  update public.profiles set couple_id = null where couple_id = p_couple;
  -- consumed_by stays null: nobody redeemed these, the couple ended under them.
  update public.pairing_invites set consumed_at = now()
   where couple_id = p_couple and consumed_at is null;
  update public.couples
     set active = false,
         -- Starts the 30-day clock. NOTE: the comment this replaces claimed
         -- "Re-pairing clears it, so a reconciliation inside the window keeps
         -- everything." That is false and has been since 20260601005900 —
         -- create_pairing_invite mints a NEW couple for a caller with none, and
         -- redeem_pairing_invite raises couple_dissolved for any invite
         -- pointing at a dissolved one. There is no path back to this
         -- couple_id today; restoring one is a later migration.
         dissolved_at = coalesce(dissolved_at, now())
   where id = p_couple;
end;
$fn$;

-- Internal only. A client that could name a couple id could dissolve a couple
-- it does not belong to; the identity check lives in the wrapper.
revoke execute on function public.dissolve_couple(uuid)
  from public, anon, authenticated;

create or replace function public.leave_couple()
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare v_uid uuid := auth.uid(); v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then return; end if;
  perform public.dissolve_couple(v_couple);
end;
$fn$;

-- ── Starting: 24 hours, two gates, a limit, and a partner ────────────────

create or replace function public.unlink_start()
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
  v_recent integer;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then raise exception 'no_active_couple'; end if;
  if not exists (
    select 1 from public.couples where id = v_couple and active
  ) then
    raise exception 'no_active_couple';
  end if;

  -- §200, from the server side this time. The sheet already asks
  -- sessionProvider.partner != null, but a couple of one that reached this
  -- RPC used to open a seven-day goodbye with nobody to tell — and then the
  -- client turned the resulting silence into "nothing happens when I press".
  if not exists (
    select 1 from public.profiles where couple_id = v_couple and id <> v_uid
  ) then
    raise exception 'no_partner';
  end if;

  select count(*) into v_recent
    from public.unlink_starts
   where couple_id = v_couple
     and started_at > now() - interval '24 hours';
  if v_recent >= 3 then raise exception 'too_many_attempts'; end if;

  begin
    insert into public.couple_unlink (
      couple_id, initiated_by,
      cooling_ends_at, relink_opens_at, partner_gate_opens_at
    )
    values (
      v_couple, v_uid,
      now() + interval '24 hours',
      now() + interval '15 minutes',
      now() + interval '15 minutes'
    );
  exception when unique_violation then
    raise exception 'already_started';
  end;

  insert into public.unlink_starts (couple_id, initiated_by)
  values (v_couple, v_uid);
end;
$fn$;

-- ── Cancelling: still ungated, still initiator-only ──────────────────────
--
-- The 15-minute wait before Re-link APPEARS is a ritual, and it is enforced
-- in the UI where rituals belong. It is deliberately not enforced here:
--
--   * Cancelling is the safe direction. It re-links and destroys nothing, so
--     a gate buys no safety.
--   * A server gate would make build 65's Re-link button — the only caller of
--     this RPC in the shipped client — throw for the first fifteen minutes of
--     every ceremony. A control that does nothing is the exact failure this
--     whole feature exists to stop being.
--
-- What is new: the partner is TOLD. Realtime covers a partner with the app
-- open; a partner whose phone is in a pocket would otherwise sit on a ritual
-- screen that has already been called off.

create or replace function public.unlink_cancel()
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
  v_url    text;
  v_gone   boolean := false;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then return; end if;

  delete from public.couple_unlink
   where couple_id = v_couple and initiated_by = v_uid
  returning true into v_gone;

  if not coalesce(v_gone, false) then return; end if;

  v_url := public.functions_base_url();
  if v_url is null then
    raise warning 'unlink_cancel: functions_base_url not configured, '
                  'partner not told the ceremony was called off';
    return;
  end if;
  perform net.http_post(
    url     := v_url || '/functions/v1/reach-notify',
    body    := jsonb_build_object(
      'kind',   'unlink_relinked',
      'record', jsonb_build_object(
        'couple_id',    v_couple,
        'initiated_by', v_uid
      )
    ),
    headers := jsonb_build_object(
      'Content-Type',    'application/json',
      'x-notify-secret', coalesce(public.notify_secret(), '')
    )
  );
end;
$fn$;

-- ── Accepting: gated, and a five-minute last call ────────────────────────
--
-- The old shape gave the partner a second 24 hours. The new one ends things
-- in five minutes — but only after the initiator has had a live Re-link
-- button in front of them, and only after they are told their partner agreed.
-- That push is the point: "she is ready to let go" is the sentence that stops
-- most of these, and it arrives while there is still a button.

create or replace function public.unlink_accept()
returns void
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then raise exception 'no_active_couple'; end if;
  update public.couple_unlink
     set state             = 'last_look',
         accepted_by       = v_uid,
         accepted_at       = now(),
         last_look_ends_at = least(cooling_ends_at, now() + interval '5 minutes'),
         updated_at        = now()
   where couple_id = v_couple
     and state = 'cooling'
     and initiated_by is distinct from v_uid
     and now() >= coalesce(partner_gate_opens_at,
                           started_at + interval '15 minutes');
  if not found then raise exception 'nothing_to_accept'; end if;
end;
$fn$;

-- ── The last-call push ───────────────────────────────────────────────────
--
-- Explicit recipient: this one goes to the INITIATOR, which is the reverse of
-- every other unlink push, so it cannot ride the other-member lookup.

create or replace function public.notify_unlink_lastcall()
returns trigger
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_url text := public.functions_base_url();
begin
  if v_url is null then
    raise warning 'notify_unlink_lastcall: functions_base_url not configured';
    return new;
  end if;
  perform net.http_post(
    url     := v_url || '/functions/v1/reach-notify',
    body    := jsonb_build_object(
      'kind',      'unlink_lastcall',
      'recipient', new.initiated_by,
      'record',    jsonb_build_object(
        'couple_id',    new.couple_id,
        'initiated_by', new.initiated_by
      )
    ),
    headers := jsonb_build_object(
      'Content-Type',    'application/json',
      'x-notify-secret', coalesce(public.notify_secret(), '')
    )
  );
  return new;
end;
$fn$;

revoke execute on function public.notify_unlink_lastcall()
  from public, anon, authenticated;

drop trigger if exists couple_unlink_lastcall on public.couple_unlink;
create trigger couple_unlink_lastcall
  after update of state on public.couple_unlink
  for each row
  when (old.state = 'cooling' and new.state = 'last_look')
  execute function public.notify_unlink_lastcall();

-- ── The job that finishes it ─────────────────────────────────────────────
--
-- Members are read BEFORE dissolving, because dissolve_couple() nulls
-- profiles.couple_id and reach-notify's other-member lookup would then find
-- nobody. Both are addressed explicitly, the way deliver_rituals() does it.
--
-- The due set is materialised into an array first: the dissolution fires
-- trg_unlink_dies_with_couple, which deletes the very row a FOR-cursor would
-- still be standing on.

create or replace function public.unlink_expire_due()
returns integer
language plpgsql
security definer
set search_path = public
as $fn$
declare
  v_url     text := public.functions_base_url();
  v_due     uuid[];
  v_couple  uuid;
  v_members uuid[];
  v_member  uuid;
  v_n       integer := 0;
begin
  select coalesce(array_agg(couple_id), '{}')
    into v_due
    from public.couple_unlink
   where coalesce(last_look_ends_at, cooling_ends_at) <= now();

  if array_length(v_due, 1) is null then return 0; end if;

  foreach v_couple in array v_due loop
    select coalesce(array_agg(id), '{}') into v_members
      from public.profiles where couple_id = v_couple;

    perform public.dissolve_couple(v_couple);
    -- trg_unlink_dies_with_couple removes the ceremony row. Belt and braces
    -- for a couple already dissolved by another door, whose trigger therefore
    -- never fired: without this the job would re-select it forever.
    delete from public.couple_unlink where couple_id = v_couple;
    v_n := v_n + 1;

    if v_url is not null then
      foreach v_member in array v_members loop
        perform net.http_post(
          url     := v_url || '/functions/v1/reach-notify',
          body    := jsonb_build_object(
            'kind',      'unlink_ended',
            'recipient', v_member,
            'record',    jsonb_build_object(
              'couple_id',    v_couple,
              'initiated_by', v_member
            )
          ),
          headers := jsonb_build_object(
            'Content-Type',    'application/json',
            'x-notify-secret', coalesce(public.notify_secret(), '')
          )
        );
      end loop;
    end if;
  end loop;

  if v_n > 0 then
    raise notice 'unlink_expire_due: dissolved % couple(s)', v_n;
  end if;
  if v_url is null and v_n > 0 then
    raise warning 'unlink_expire_due: functions_base_url unset — % couple(s) '
                  'dissolved with nobody told', v_n;
  end if;
  return v_n;
end;
$fn$;

revoke execute on function public.unlink_expire_due()
  from public, anon, authenticated;

-- Every minute, exactly like deliver-rituals. unlink_execute() stays: a human
-- who opens the app past the deadline finishes it instantly instead of
-- waiting out the tick.
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'unlink-expire-due') then
      perform cron.unschedule('unlink-expire-due');
    end if;
    perform cron.schedule('unlink-expire-due', '* * * * *',
                          $j$select public.unlink_expire_due();$j$);

    if exists (select 1 from cron.job where jobname = 'prune-unlink-starts') then
      perform cron.unschedule('prune-unlink-starts');
    end if;
    perform cron.schedule('prune-unlink-starts', '31 4 * * *',
                          $j$select public.prune_unlink_starts();$j$);
  else
    raise warning 'pg_cron absent: the ceremony will only finish when a '
                  'partner opens the app';
  end if;
end
$do$;

-- ── The robot rail goes quiet — NOT here ─────────────────────────────────
--
-- "Your daily prompt is ready" arriving in the middle of this is the app
-- failing to read the room, so the ritual rail has to be muted. This file is
-- deliberately NOT where that happens.
--
-- The first draft rebuilt deliver_rituals() from its live production body with
-- one `not exists (... couple_unlink ...)` clause added. Applying that to
-- staging failed:
--
--     ERROR: 42703: column "deleted" does not exist
--     CONTEXT: PL/pgSQL function deliver_rituals() line 14
--
-- Production's rituals table has a `deleted` column. Staging's does not, and
-- NO MIGRATION IN THIS REPO ADDS IT — 20260815073233 already reads it, so that
-- file cannot replay onto a clean database either. That is a pre-existing
-- defect, and it is not this feature's to fix.
--
-- The mute therefore lives in reach-notify, which is the one place every push
-- already passes through: it refuses kind 'ritual' while a ceremony row exists
-- for that couple. Schema-independent, one query, and it covers any future
-- robot rail without this file having to know the shape of its table.
--
-- care nudges are deliberately NOT muted: a nudge is a human reaching out, and
-- the whole design of this window is that reaching out still works.

-- ── Assertions ───────────────────────────────────────────────────────────

do $assert$
begin
  -- 1. Still RPC-only for writes, and the new ledger is invisible.
  if has_table_privilege('authenticated', 'public.couple_unlink', 'INSERT')
     or has_table_privilege('authenticated', 'public.couple_unlink', 'UPDATE')
     or has_table_privilege('authenticated', 'public.couple_unlink', 'DELETE')
  then
    raise exception 'couple_unlink must be RPC-only for writes';
  end if;
  if has_table_privilege('authenticated', 'public.unlink_starts', 'SELECT') then
    raise exception 'the rate-limit ledger must not be readable by a client';
  end if;

  -- 2. THE EXITS ARE NEVER GATED ON THE CEREMONY. This is assertion #4 of
  --    20260829120000, re-run here because this file rewrites leave_couple().
  --    The wrapper and dissolve_couple() must both be innocent of the word.
  if position('couple_unlink'
       in pg_get_functiondef('public.leave_couple()'::regprocedure)) > 0
     or position('couple_unlink'
       in pg_get_functiondef('public.leave_couple_permanently()'::regprocedure)) > 0
     or position('couple_unlink'
       in pg_get_functiondef('public.dissolve_couple(uuid)'::regprocedure)) > 0
  then
    raise exception 'the exits must never reference couple_unlink';
  end if;

  -- 3. The split kept the scrub. leave_couple() delegating to a
  --    dissolve_couple() that forgot the presence wipe would leak both
  --    partners' coordinates through every future breakup, silently.
  if position('location_sharing_mode'
       in pg_get_functiondef('public.dissolve_couple(uuid)'::regprocedure)) = 0
  then
    raise exception 'dissolve_couple lost the presence scrub';
  end if;
  if position('dissolve_couple'
       in pg_get_functiondef('public.leave_couple()'::regprocedure)) = 0
  then
    raise exception 'leave_couple no longer dissolves anything';
  end if;

  -- 4. Naming a couple you are not in must stay impossible.
  if has_function_privilege('authenticated',
       'public.dissolve_couple(uuid)', 'EXECUTE')
     or has_function_privilege('authenticated',
       'public.unlink_expire_due()', 'EXECUTE')
  then
    raise exception 'dissolve_couple/unlink_expire_due must not be client-callable';
  end if;

  -- 5. Self-accept guard, still there (assertion #3 of 20260829120000).
  if position('initiated_by is distinct from'
       in pg_get_functiondef('public.unlink_accept()'::regprocedure)) = 0
  then
    raise exception 'unlink_accept lost its self-accept guard';
  end if;

  -- 6. Accepting still cannot EXTEND the window.
  if position('least(cooling_ends_at'
       in pg_get_functiondef('public.unlink_accept()'::regprocedure)) = 0
  then
    raise exception 'unlink_accept lost the clamp to the cooling deadline';
  end if;

  -- 7. Cancelling stays ungated. A future session tightening this would turn
  --    every shipped Re-link button into a control that throws.
  if position('relink_opens_at'
       in pg_get_functiondef('public.unlink_cancel()'::regprocedure)) > 0
  then
    raise exception 'unlink_cancel must never be time-gated';
  end if;

  -- 8. The job is actually scheduled. A migration that reports success while
  --    the only thing that can finish a ceremony was never registered is the
  --    exact silent no-op this repo has shipped before.
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if not exists (
      select 1 from cron.job
       where jobname = 'unlink-expire-due' and active
    ) then
      raise exception 'unlink-expire-due is not scheduled';
    end if;
  end if;
end
$assert$;

-- ── ROLLBACK ─────────────────────────────────────────────────────────────
--
--   do $r$ begin
--     if exists (select 1 from cron.job where jobname = 'unlink-expire-due')
--       then perform cron.unschedule('unlink-expire-due'); end if;
--     if exists (select 1 from cron.job where jobname = 'prune-unlink-starts')
--       then perform cron.unschedule('prune-unlink-starts'); end if;
--   end $r$;
--   drop trigger  if exists couple_unlink_lastcall on public.couple_unlink;
--   drop function if exists public.notify_unlink_lastcall();
--   drop function if exists public.unlink_expire_due();
--   drop function if exists public.prune_unlink_starts();
--   drop table    if exists public.unlink_starts;
--   alter table public.couple_unlink
--     drop column if exists relink_opens_at,
--     drop column if exists partner_gate_opens_at;
--
--   -- Then REPLAY these two files' definitions, in this order:
--   --   20260826140000 -> leave_couple() with its body inlined again
--   --   20260829120000 -> unlink_start() 7d, unlink_accept() 24h,
--   --                     unlink_cancel() without the notify
--   drop function if exists public.dissolve_couple(uuid);
--
--   -- reach-notify: redeploy the previous version (the ritual mute and the
--   -- three unlink kinds live there, not here).
--
-- Nothing is lost either direction. The two new columns are nullable and the
-- client defaults them; unlink_starts is a limiter's ledger with no user data.
-- A ceremony already executed stays executed and keeps its ordinary 30-day
-- restore window. Ceremonies in flight keep running, on the old rules.
--
-- Second run of this file: no-op. Columns and table are IF NOT EXISTS, every
-- function is CREATE OR REPLACE, the trigger and the cron jobs are dropped or
-- unscheduled before being recreated, and the assertions are read-only.
