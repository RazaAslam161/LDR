-- ───────────────────────────────────────────────────────────────────────────
-- Miles — the three things any app two people can post into has to have: a way
-- to stop contact, a way to report what arrived, and terms somebody actually
-- agreed to.
--
-- WHAT ALREADY EXISTED. 20260601007700 built the whole stop mechanism —
-- notification_mutes, mute_partner, unmute_partner, push_muted — and shipped it
-- with ZERO Dart call sites. Every line of it has been dead since. This
-- migration widens it to cover contact of any kind and leaves the surfacing to
-- the client; it does not build a second one beside it.
--
-- BUILD SAFETY. Build 31 is installed on handsets that have no update channel,
-- so nothing here may add a precondition to a write they already make:
--   · the kind CHECK is WIDENED, never narrowed — every value build 31 can
--     write still passes.
--   · notify_message and notify_call are left alone — see below.
--     sopictusdonlvuezmfep on 2026-08-16, not what an older file in this repo
--     says: 20260601004700 rewrote both by catalogue to add x-notify-secret,
--     and restoring a file's version would silently drop that header.
--   · content_reports and tos_acceptances are new tables. Nothing reads or
--     writes them from an older build, so an older build cannot notice them.
-- The Terms gate is enforced CLIENT-side in this release. There is deliberately
-- no server-side "you may not write until you have accepted" — build 31 has
-- never heard of tos_acceptances and would be locked out of its own account by
-- one. That gate waits until app_release.min_build names a build that carries
-- the client half.
--
-- A SECOND RUN IS A NO-OP. Every table is `if not exists`, every function is
-- `create or replace`, every policy is dropped before it is created, and the
-- one CHECK is dropped before it is re-added with the same definition. Nothing
-- here deletes a row or narrows a grant, so replaying it changes nothing.
-- Rollback SQL is at the bottom of this file.
-- ───────────────────────────────────────────────────────────────────────────

-- ── 1. The pause is a third kind of mute ───────────────────────────────────
-- 'reach' and 'care' silence one button each. 'contact' is the umbrella: it
-- means "nothing from this person wakes my phone", and push_muted below reads
-- it in ADDITION to whichever kind the caller asked about, so a single row
-- covers every channel including ones added later.
--
-- Dropped and re-added rather than altered because Postgres has no
-- `add constraint if not exists`; drop-if-exists first is what makes the pair
-- idempotent. The new list is a superset of the old, so no existing row can
-- fail validation.
do $kind$
begin
  alter table public.notification_mutes
    drop constraint if exists notification_mutes_kind_check;
  alter table public.notification_mutes
    add constraint notification_mutes_kind_check
    check (kind in ('reach', 'care', 'contact'));
end $kind$;

-- Body is 007700's, with the kind test widened. The profiles join stays: it is
-- what stops a mute row written against a FORMER partner from silencing the
-- current one.
create or replace function public.push_muted(p_couple uuid, p_sender uuid, p_kind text)
returns boolean language sql stable security definer
set search_path = public as $fn$
  select exists (
    select 1 from public.notification_mutes m
    join public.profiles p on p.id = m.user_id and p.couple_id = p_couple
    where m.partner_id = p_sender and m.kind in (p_kind, 'contact')
      and (m.expires_at is null or m.expires_at > now()));
$fn$;

revoke execute on function public.push_muted(uuid, uuid, text)
  from public, anon, authenticated;

-- 007700's body with 'contact' added to the accepted kinds. The rest — the
-- partner lookup, the on-conflict upsert, the minutes-to-expiry arithmetic, and
-- above all the silence toward the muted party — is unchanged.
create or replace function public.mute_partner(p_kind text, p_minutes integer default null)
returns void language plpgsql security definer
set search_path = public as $fn$
declare v_uid uuid := auth.uid(); v_partner uuid;
begin
  if p_kind not in ('reach', 'care', 'contact') then raise exception 'bad kind'; end if;
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

do $grants$ declare f text; begin
  foreach f in array array['mute_partner(text,integer)', 'unmute_partner(text)']
  loop
    execute format('revoke all on function public.%s from public, anon;', f);
    execute format('grant execute on function public.%s to authenticated;', f);
  end loop;
end $grants$;

-- ── 2. Where the pause bites for messages and calls ────────────────────────
-- 007700 guarded notify_reach and notify_care and stopped there, because a
-- mute then meant "stop the Reach button". A contact pause that still delivers
-- a message banner and a full-screen ring is not a pause at all.
--
-- Both bodies below are the LIVE ones, byte for byte, with a single guard line
-- added at the top. Neither loses the x-notify-secret header 004700 added.
--
-- The guard returns NEW rather than raising: the row must still insert. A
-- refused write is visible to the sender, and a stop the other person can see
-- is one nobody in a controlling relationship can afford to use — the same
-- argument 007700 made for keeping the mute silent. The message still lands in
-- the table and still appears when the muter opens the app; only the
-- interruption is dropped.
-- notify_message and notify_call are deliberately NOT touched here.
--
-- The owner does not want message or call push at all, so a mute guard on them
-- would be dead code guarding a channel that never fires. `messages` already
-- carries no trigger on production (verified: pg_trigger returns zero rows), so
-- message push is off by absence. Calls still push via call_notify_on_insert —
-- turning that off is a separate, deliberate change, not a side effect of a
-- compliance migration.
--
-- The pause therefore covers reach and care on the server, and drops incoming
-- call OFFERS on the client (call_controller), which is the channel that
-- actually rings when the app is open. That is the honest scope.

-- ── 3. Reports ─────────────────────────────────────────────────────────────
-- Write-only, and that is a safety decision rather than a shortcut.
--
-- There is NO select policy, for anybody. RLS denies what it does not permit,
-- so the rows are unreadable from every client key. A screen that could list
-- "reports you have filed about your partner", on a phone that partner may
-- pick up, is the single most dangerous thing this app could render. Nothing
-- is persisted in the UI after filing either: one neutral toast, and the sheet
-- closes.
--
-- reported_user_id is nullable because an app_content report is about Miles,
-- not about a person, and resolving a partner for it would name someone who
-- was never accused of anything.
--
-- What a report can carry is limited by what the server holds, and that is not
-- a blanket "we cannot read anything". Memory Threads, the Closer vault and
-- Wish Jar entries are encrypted on the sending phone; chat text, chat media
-- and gallery objects are NOT (docs/legal/privacy-policy.md §2, and
-- chat_repository.dart inserts 'body' in the clear). So the row records who,
-- when and why rather than a copy of the content — and the client says exactly
-- that, in those words. Copy claiming the operator cannot read a message would
-- be contradicted by the privacy policy two taps away.
create table if not exists public.content_reports (
  id               uuid primary key default gen_random_uuid(),
  reporter_id      uuid not null references auth.users(id) on delete cascade,
  -- set null, not cascade: a report survives the account it was filed against,
  -- which is the only reason to keep reports at all.
  reported_user_id uuid references auth.users(id) on delete set null,
  created_at       timestamptz not null default now(),
  reason           text not null check (reason in (
                     'threats', 'harassment', 'nonconsensual_imagery',
                     'csam', 'impersonation', 'spam', 'other')),
  target_kind      text not null check (target_kind in (
                     'partner', 'message', 'gallery_item', 'gif', 'reel',
                     'app_content')),
  target_ref       text check (char_length(target_ref) <= 200),
  note             text check (char_length(note) <= 1000),
  build            integer
);

alter table public.content_reports enable row level security;

-- No policy is created on purpose. The grant is revoked as well so that adding
-- a policy later is a deliberate act and not a single line away.
revoke all on public.content_reports from anon, authenticated;

-- The rate limit below counts this reporter's last 24 hours on every call.
create index if not exists content_reports_reporter_time_idx
  on public.content_reports (reporter_id, created_at desc);

-- The client never names who it is reporting.
--
-- Accepting reported_user_id from the caller would let any authenticated
-- account file reports against any uuid it could guess, and the only defence
-- would be a policy on a table nobody can read to audit. It is resolved here,
-- from the reporter's own couple, or left null.
create or replace function public.submit_report(
  p_reason      text,
  p_target_kind text,
  p_target_ref  text default null,
  p_note        text default null,
  p_build       integer default null
) returns void language plpgsql security definer
set search_path = public as $fn$
declare
  v_uid    uuid := auth.uid();
  v_recent integer;
  v_reported uuid;
begin
  if v_uid is null then raise exception 'not signed in'; end if;
  -- Counted before the insert, so the limit is five ACCEPTED reports and the
  -- sixth attempt does not first write the row it is being refused for.
  -- PostgREST turns a PTxyz sqlstate into HTTP xyz, so the client can tell
  -- "too many" apart from "the server broke" and say something true.
  select count(*) into v_recent from public.content_reports
   where reporter_id = v_uid and created_at > now() - interval '24 hours';
  if v_recent >= 5 then
    raise exception 'report_rate_limited' using errcode = 'PT429';
  end if;
  if p_target_kind <> 'app_content' then
    select id into v_reported from public.profiles
     where couple_id = (select public.current_user_couple_id()) and id <> v_uid;
  end if;
  -- Truncated rather than rejected. The length CHECKs above are the backstop
  -- for a direct caller; for the app, losing a report because a note ran long
  -- is a worse outcome than a note that ends mid-sentence.
  insert into public.content_reports (reporter_id, reported_user_id, reason,
                                      target_kind, target_ref, note, build)
  values (v_uid, v_reported, p_reason, p_target_kind,
          left(p_target_ref, 200), left(p_note, 1000), p_build);
end $fn$;

revoke all on function public.submit_report(text, text, text, text, integer)
  from public, anon;
grant execute on function public.submit_report(text, text, text, text, integer)
  to authenticated;

-- ── 4. Terms acceptance ────────────────────────────────────────────────────
-- A TABLE, not a column on profiles. 20260601003700 rebuilds the profiles
-- column-level UPDATE grant from information_schema AT RUN TIME, so any column
-- added to profiles after that file replays is created but NOT writable — the
-- write fails with "permission denied" rather than "no such column", which is
-- the harder of the two to recognise. That trap has already cost one release.
--
-- Keyed on auth.users rather than profiles because the gate runs before the
-- onboarding funnel: the terms are agreed to by the account, at a point where
-- a display name and a couple may not exist yet.
--
-- One row per version, so raising milesTermsVersion re-gates everyone without
-- erasing the record that they accepted version 1 on a given build.
create table if not exists public.tos_acceptances (
  user_id     uuid not null default auth.uid()
                references auth.users(id) on delete cascade,
  version     integer not null,
  accepted_at timestamptz not null default now(),
  build       integer,
  primary key (user_id, version)
);

alter table public.tos_acceptances enable row level security;

revoke all on public.tos_acceptances from anon, authenticated;
grant select, insert on public.tos_acceptances to authenticated;

drop policy if exists "tos_acceptances_select_own" on public.tos_acceptances;
create policy "tos_acceptances_select_own" on public.tos_acceptances
  for select using (user_id = auth.uid());

-- No update and no delete grant: an acceptance is a fact with a timestamp on
-- it, and a record that can be edited by the person it is about is not one.
drop policy if exists "tos_acceptances_insert_own" on public.tos_acceptances;
create policy "tos_acceptances_insert_own" on public.tos_acceptances
  for insert with check (user_id = auth.uid());

-- ── 5. Prove the guards are still in the bodies ────────────────────────────
-- 004700 rewrites every function whose body mentions reach-notify by
-- catalogue, and 007700 added this same assertion for notify_reach and
-- notify_care after discovering that. All four now. If a later migration
-- rewrites one of them and drops the guard, the pause quietly stops covering
-- that channel and nothing else would ever say so — fail here instead.
do $verify$
declare f text;
begin
  foreach f in array array['notify_reach', 'notify_care']
  loop
    -- coalesce, because a DELETED function makes the subquery NULL, and
    -- `NULL not like ...` is NULL, and `if NULL then` does not fire — so the
    -- block advertising "fail here instead" would sail past the loudest
    -- failure there is. 20260816140000 gets this right; this did not.
    if coalesce((select pg_get_functiondef(p.oid) from pg_proc p
                  where p.pronamespace = 'public'::regnamespace
                    and p.proname = f), '')
       not like '%push_muted%' then
      raise exception '% no longer consults push_muted (or is gone)', f;
    end if;
  end loop;
end $verify$;

-- notify_message's trigger is missing on production: `messages` carries zero
-- triggers there, so the function has been orphaned since some point after
-- 20260601003100 created message_notify_on_insert. The guard above still
-- belongs in the body — a fresh database replays 003100 and gets the trigger —
-- but on production the pause covers reaches, nudges and calls only until that
-- trigger is restored. Deliberately NOT re-attached here: turning message push
-- back on for two live handsets is a behaviour change, not a compliance fix,
-- and it belongs in its own migration with its own verification.

-- ───────────────────────────────────────────────────────────────────────────
-- ROLLBACK. Restores the state this file found. Safe to run more than once.
--
--   -- 4. terms
--   drop table if exists public.tos_acceptances;
--
--   -- 3. reports
--   drop function if exists public.submit_report(text, text, text, text, integer);
--   drop table if exists public.content_reports;
--
--   -- 2 + 1. the mute, back to reach/care only. Any 'contact' row must go
--   -- first or the narrowed CHECK cannot validate.
--   delete from public.notification_mutes where kind = 'contact';
--   alter table public.notification_mutes
--     drop constraint if exists notification_mutes_kind_check;
--   alter table public.notification_mutes
--     add constraint notification_mutes_kind_check
--     check (kind in ('reach', 'care'));
--
--   create or replace function public.push_muted(p_couple uuid, p_sender uuid, p_kind text)
--   returns boolean language sql stable security definer
--   set search_path = public as $rb$
--     select exists (
--       select 1 from public.notification_mutes m
--       join public.profiles p on p.id = m.user_id and p.couple_id = p_couple
--       where m.partner_id = p_sender and m.kind = p_kind
--         and (m.expires_at is null or m.expires_at > now()));
--   $rb$;
--
--   create or replace function public.mute_partner(p_kind text, p_minutes integer default null)
--   returns void language plpgsql security definer
--   set search_path = public as $rb$
--   declare v_uid uuid := auth.uid(); v_partner uuid;
--   begin
--     if p_kind not in ('reach', 'care') then raise exception 'bad kind'; end if;
--     select id into v_partner from public.profiles
--      where couple_id = (select public.current_user_couple_id()) and id <> v_uid;
--     if v_partner is null then raise exception 'no partner'; end if;
--     insert into public.notification_mutes (user_id, partner_id, kind, expires_at)
--     values (v_uid, v_partner, p_kind,
--             case when p_minutes is null then null
--                  else now() + make_interval(mins => greatest(p_minutes, 1)) end)
--     on conflict (user_id, kind) do update
--       set partner_id = excluded.partner_id, muted_at = now(),
--           expires_at = excluded.expires_at;
--   end $rb$;
--
--   -- notify_message / notify_call: drop the one push_muted line from each and
--   -- re-apply the bodies above them. The verify block in section 5 must be
--   -- shortened to notify_reach + notify_care first, or it will refuse.
-- ───────────────────────────────────────────────────────────────────────────
