-- ───────────────────────────────────────────────────────────────────────────
-- Miles — Reach is a button that wakes another person's screen, and until this
-- migration nothing on the server limited it and nothing could switch it off.
--
-- THE CHANNEL. An insert into reach_events fires notify_reach, which POSTs to
-- reach-notify, which sends a high-priority data push; the receiving handler
-- builds a notification with Importance.max, AndroidNotificationCategory.call
-- and fullScreenIntent (reach_notifications.dart:60-71). One row = one lit
-- screen and a vibration pattern, through a locked phone, at any hour.
--
-- THE LIMIT THAT WASN'T. The only cooldown was `_cooldownUntil` in widget State
-- (reach_button.dart:20-46). It is reset by an app restart, it is per-widget,
-- and it does not exist at all for a caller who posts to
-- /rest/v1/reach_events directly — the same token the app carries passes the
-- insert policy, which checks who you are and never how often. The ceiling was
-- the network's.
--
-- THE STOP THAT WASN'T. Grepping supabase/migrations and mobile/lib for
-- block/mute/report returned nothing. The only way to stop a partner reaching
-- you was to dissolve the couple — which erases the relationship to silence a
-- notification, and in the situation where someone actually needs this, is the
-- one move they cannot safely make.
--
-- Both fixes are server-side and additive: build 21 keeps inserting into the
-- table and is now bounded by the trigger, so no version gate is needed.
-- ───────────────────────────────────────────────────────────────────────────

-- ── The policy, in one place ────────────────────────────────────────────────
-- Two rules per table because they answer different attacks. The minimum gap
-- kills the burst (five rows in one second is five screens lit at once); the
-- window cap kills the grind (one row every gap, forever, is the same abuse
-- spread thin). Returns the instant the sender may next insert, or null when
-- they may insert now.
--
-- Calibrated against what the table actually holds: 31 reaches ever, and the
-- busiest sender-hour in that history is 3 (mean 1.41). Every threshold below
-- is far above honest use and far below "wake her up until she answers".
--
--   reach_events  1 per 30s, 5 per 5min. The 30s is not a new rule — it is the
--                 one reach_button.dart has always drawn ("Wait 30s") and
--                 never enforced, and it matches the row's own 30s expires_at:
--                 a second Reach while the first is still live has nothing to
--                 say. 5 per 5 minutes then caps a determined sender at one
--                 wake a minute instead of one every thirty seconds forever.
--   care_nudges   1 per 30s, 10 per hour. Same push, lower urgency, and a
--                 nudge is composed rather than held — 19 exist in total.
--   call_invites  1 per 15s, 10 per 10min. Deliberately the loosest: redialling
--                 IS how you reach someone who missed you, and a rate limit
--                 that blocks the third try in an emergency is worse than the
--                 abuse it prevents. Fifteen seconds is shorter than the ring
--                 itself, so only a script notices.
create or replace function public.send_next_allowed_at(p_table text, p_sender uuid)
returns timestamptz language plpgsql stable security definer
set search_path = public as $fn$
declare
  v_col text; v_gap interval; v_burst int; v_window interval; v_at timestamptz;
begin
  case p_table
    when 'reach_events' then
      v_col := 'from_user'; v_gap := interval '30 seconds';
      v_burst := 5;  v_window := interval '5 minutes';
    when 'care_nudges' then
      v_col := 'from_user'; v_gap := interval '30 seconds';
      v_burst := 10; v_window := interval '1 hour';
    when 'call_invites' then
      v_col := 'caller_id'; v_gap := interval '15 seconds';
      v_burst := 10; v_window := interval '10 minutes';
    else raise exception 'no send rate defined for %', p_table;
  end case;
  -- greatest() ignores nulls, so a sender with no history at all — or fewer
  -- than v_burst rows ever — gets null and is waved through.
  execute format($q$
    select greatest(
      (select max(created_at) from public.%1$I where %2$I = $1) + $2,
      (select created_at from public.%1$I where %2$I = $1
        order by created_at desc offset $3 limit 1) + $4)
  $q$, p_table, v_col)
  into v_at using p_sender, v_gap, v_burst - 1, v_window;
  return v_at;
end $fn$;

-- BEFORE INSERT, so the row never exists and the AFTER trigger never pushes.
-- The sender column is from_user on both event tables and caller_id on
-- call_invites; naming both here keeps the trigger definitions argument-free
-- and the thresholds above the single source of truth.
create or replace function public.enforce_send_rate()
returns trigger language plpgsql security definer
set search_path = public as $fn$
declare
  v_sender uuid := (coalesce(to_jsonb(new) ->> 'from_user',
                             to_jsonb(new) ->> 'caller_id'))::uuid;
begin
  if public.send_next_allowed_at(tg_table_name, v_sender) > now() then
    -- PostgREST turns a PTxyz sqlstate into HTTP xyz, so the client sees 429
    -- rather than a 500 that looks like the server broke.
    raise exception 'rate_limited' using errcode = 'PT429';
  end if;
  return new;
end $fn$;

revoke execute on function public.send_next_allowed_at(text, uuid)
  from public, anon, authenticated;
revoke execute on function public.enforce_send_rate() from public, anon, authenticated;

drop trigger if exists reach_events_rate_limit on public.reach_events;
create trigger reach_events_rate_limit before insert on public.reach_events
  for each row execute function public.enforce_send_rate();

drop trigger if exists care_nudges_rate_limit on public.care_nudges;
create trigger care_nudges_rate_limit before insert on public.care_nudges
  for each row execute function public.enforce_send_rate();

drop trigger if exists call_invites_rate_limit on public.call_invites;
create trigger call_invites_rate_limit before insert on public.call_invites
  for each row execute function public.enforce_send_rate();

-- Every existing index on these tables is keyed on couple_id or is the two
-- bare from_user indexes 004200 added; none of them can answer "this sender's
-- most recent N, newest first" without a sort. The limiter runs on every
-- insert, so it gets its own.
create index if not exists reach_events_sender_time_idx
  on public.reach_events (from_user, created_at desc);
create index if not exists care_nudges_sender_time_idx
  on public.care_nudges (from_user, created_at desc);
create index if not exists call_invites_sender_time_idx
  on public.call_invites (caller_id, created_at desc);

-- ── The stop ───────────────────────────────────────────────────────────────
-- One row per person per kind: "do not push me this, from this partner".
--
-- partner_id is stored rather than inferred from the couple because couples
-- dissolve and re-pair. A mute keyed on the muter alone would survive that and
-- silently swallow the next partner's Reaches with nothing anywhere to explain
-- it; keyed on who was muted, it simply stops applying.
--
-- Kinds are 'reach' and 'care'. Calls are deliberately not mutable here: a
-- silenced call is a missed emergency, and this app has no other channel that
-- reaches a closed phone. Muting Reach already stops the screen-waking.
create table if not exists public.notification_mutes (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  partner_id uuid not null references public.profiles(id) on delete cascade,
  kind       text not null check (kind in ('reach', 'care')),
  muted_at   timestamptz not null default now(),
  -- null = until lifted. A timed pause ("two hours") is the same row.
  expires_at timestamptz,
  primary key (user_id, kind),
  check (partner_id <> user_id)
);

alter table public.notification_mutes enable row level security;

-- Writes go through the RPCs below, which assert the pair. A user who can
-- INSERT here directly can write any partner_id, and a user who can SELECT
-- another row learns they were muted — see the silence argument below.
revoke all on public.notification_mutes from anon, authenticated;
grant select on public.notification_mutes to authenticated;

drop policy if exists "notification_mutes_select_own" on public.notification_mutes;
create policy "notification_mutes_select_own" on public.notification_mutes
  for select using (user_id = auth.uid());

-- The recipient is resolved through profiles rather than assumed: the trigger
-- knows couple_id and the sender, not who is on the other end. Without the
-- join a mute row written by a FORMER partner of the sender would match and
-- silence the current one.
create or replace function public.push_muted(p_couple uuid, p_sender uuid, p_kind text)
returns boolean language sql stable security definer
set search_path = public as $fn$
  select exists (
    select 1 from public.notification_mutes m
    join public.profiles p on p.id = m.user_id and p.couple_id = p_couple
    where m.partner_id = p_sender and m.kind = p_kind
      and (m.expires_at is null or m.expires_at > now()));
$fn$;

revoke execute on function public.push_muted(uuid, uuid, text)
  from public, anon, authenticated;

-- Muting is silent to the muted. There is no notification, no column the
-- sender can read (the select policy is own-rows-only) and no error on their
-- send — the row still inserts and still arrives in the app when the muter
-- opens it. A mute that announces itself is one nobody in a controlling
-- relationship can afford to use, which makes it not a mute at all.
create or replace function public.mute_partner(p_kind text, p_minutes integer default null)
returns void language plpgsql security definer
set search_path = public as $fn$
declare v_uid uuid := auth.uid(); v_partner uuid;
begin
  if p_kind not in ('reach', 'care') then raise exception 'bad kind'; end if;
  select id into v_partner from public.profiles
   where couple_id = (select public.current_user_couple_id()) and id <> v_uid;
  if v_partner is null then raise exception 'no partner'; end if;
  insert into public.notification_mutes (user_id, partner_id, kind, expires_at)
  values (v_uid, v_partner, p_kind,
          case when p_minutes is null then null
               else now() + make_interval(mins => greatest(p_minutes, 1)) end)
  on conflict (user_id, kind) do update
    set partner_id = excluded.partner_id, muted_at = now(),
        expires_at = excluded.expires_at;
end $fn$;

create or replace function public.unmute_partner(p_kind text)
returns void language sql security definer
set search_path = public as $fn$
  delete from public.notification_mutes where user_id = auth.uid() and kind = p_kind;
$fn$;

do $do$ declare f text; begin
  foreach f in array array['mute_partner(text,integer)', 'unmute_partner(text)']
  loop
    execute format('revoke all on function public.%s from public, anon;', f);
    execute format('grant execute on function public.%s to authenticated;', f);
  end loop;
end $do$;

-- ── Where the mute actually bites ──────────────────────────────────────────
-- In the notifier, not in the client. Suppressing the banner on the receiving
-- handset would leave the push sent, the screen lit and the vibration played
-- before any Dart ran — the interruption IS the delivery. Bodies are otherwise
-- byte-for-byte what 004700's catalogue rewrite left live.
create or replace function public.notify_reach()
returns trigger language plpgsql security definer
set search_path = public as $fn$
declare v_url text := public.functions_base_url();
begin
  if public.push_muted(new.couple_id, new.from_user, 'reach') then return new; end if;
  if v_url is null then
    raise warning 'notify_reach: FUNCTIONS_BASE_URL unset - no push sent';
    return new;
  end if;
  perform net.http_post(
    url := v_url || '/functions/v1/reach-notify',
    body := jsonb_build_object('kind', 'reach', 'record', to_jsonb(new)),
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-notify-secret', coalesce(public.notify_secret(), ''))
  );
  return new;
end $fn$;

create or replace function public.notify_care()
returns trigger language plpgsql security definer
set search_path = public as $fn$
declare v_url text := public.functions_base_url();
begin
  if public.push_muted(new.couple_id, new.from_user, 'care') then return new; end if;
  if v_url is null then
    raise warning 'notify_care: FUNCTIONS_BASE_URL unset - no push sent';
    return new;
  end if;
  perform net.http_post(
    url := v_url || '/functions/v1/reach-notify',
    body := jsonb_build_object('kind', 'care', 'record', to_jsonb(new)),
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-notify-secret', coalesce(public.notify_secret(), ''))
  );
  return new;
end $fn$;

-- ── What the button asks ───────────────────────────────────────────────────
-- Seconds, not a timestamp: the countdown then needs only the device's clock
-- RATE, never its absolute time, which this codebase already knows it cannot
-- trust (server_clock.dart:9-13). Nulls collapse to 0 — "you may reach now".
create or replace function public.reach_cooldown_seconds()
returns integer language sql stable security definer
set search_path = public as $fn$
  select greatest(0, ceil(extract(epoch from
    coalesce(public.send_next_allowed_at('reach_events', auth.uid()), now()) - now())))::integer;
$fn$;

revoke all on function public.reach_cooldown_seconds() from public, anon;
grant execute on function public.reach_cooldown_seconds() to authenticated;

-- 004700 rewrites every function whose body mentions reach-notify by catalogue.
-- If a later migration does the same and drops these two lines, the mute goes
-- back to being a row nothing reads. Fail there, not in production.
do $do$
declare f text;
begin
  foreach f in array array['notify_reach', 'notify_care']
  loop
    if (select pg_get_functiondef(p.oid) from pg_proc p
         where p.pronamespace = 'public'::regnamespace and p.proname = f)
       not like '%push_muted%' then
      raise exception '% no longer consults push_muted', f;
    end if;
  end loop;
end $do$;
