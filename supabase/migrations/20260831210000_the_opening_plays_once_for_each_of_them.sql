-- The Opening plays once for each of them, and the app remembers it server-side.
--
-- ROLLBACK (write it before applying the forward change, not after):
--   drop function if exists public.mark_intro_finished();
--   drop function if exists public.mark_intro_started();
--   drop table if exists public.couple_intro_seen;
--
-- WHY A TABLE AND NOT A COLUMN ON couples
-- 20260815071520 revoked table-level UPDATE on public.couples and raises if it
-- is ever regranted, so a new column there would be unwritable by the client
-- by design. Every per-couple feature since August uses this shape instead: a
-- row keyed on the couple, revoke-all + grant-select, written only through a
-- security-definer RPC.
--
-- WHY THE KEY IS (couple_id, user_id) AND NOT couple_id ALONE
-- They are on two phones and will not open the app at the same moment. A
-- per-couple latch would mean whoever arrived second never saw it at all.
--
-- WHY started_at AND NOT just finished_at
-- started_at is written when the film BEGINS, not when it ends. That is the
-- whole anti-trap mechanism: intro_splash_screen.dart records that the app's
-- previous intro video "meant nobody could open the app without waiting out a
-- clip they had already seen." Once it has begun even once it can never
-- auto-play again, whatever happens next — closed mid-play, killed, crashed.
-- finished_at only decides whether Settings offers "Watch again" or "Finish
-- watching"; it is never what gates the automatic play.
--
-- WHAT A SECOND RUN OF THIS FILE DOES: nothing. The table is created only if
-- absent, the functions are replaced with identical bodies, and the insert
-- inside mark_intro_started is ON CONFLICT DO NOTHING.

create table if not exists public.couple_intro_seen (
  couple_id   uuid not null references public.couples(id)  on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  primary key (couple_id, user_id)
);

-- Both FKs carry an explicit ON DELETE per the assertion at 20260601003800:70-82.
-- A deleted account takes its own row with it; a dissolved couple takes both.

create index if not exists couple_intro_seen_user_idx
  on public.couple_intro_seen (user_id);

alter table public.couple_intro_seen enable row level security;

revoke all on public.couple_intro_seen from anon, authenticated;
grant select on public.couple_intro_seen to authenticated;

drop policy if exists couple_intro_seen_select_member on public.couple_intro_seen;
create policy couple_intro_seen_select_member on public.couple_intro_seen
  for select using (couple_id = (select public.current_user_couple_id()));

comment on table public.couple_intro_seen is
  'One row per member per couple, marking that the Opening film has played for '
  'them. Written ONLY by mark_intro_started() / mark_intro_finished(). '
  'started_at is stamped when playback begins so an interrupted viewing can '
  'never re-trap the user; finished_at only chooses the wording in Settings.';

-- ── Writes ─────────────────────────────────────────────────────────────────
-- Both derive the couple from the caller. Neither accepts a couple_id
-- argument: a write must prove the couple it claims (20260829145343), and the
-- only proof that cannot be forged by a client is auth.uid().

create or replace function public.mark_intro_started()
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  -- A user with no couple has no Opening to have seen. Silent, not an error:
  -- this is reachable by racing an unlink and is not a fault.
  if v_couple is null then return; end if;

  -- DO NOTHING, never DO UPDATE: the first start is the one that counts, and
  -- overwriting started_at on a rewatch would reopen the automatic play.
  insert into public.couple_intro_seen (couple_id, user_id)
  values (v_couple, v_uid)
  on conflict (couple_id, user_id) do nothing;
end;
$fn$;

create or replace function public.mark_intro_finished()
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then return; end if;

  -- Only the first completion is recorded; a rewatch does not restamp it.
  update public.couple_intro_seen
     set finished_at = now()
   where couple_id = v_couple
     and user_id = v_uid
     and finished_at is null;
end;
$fn$;

revoke all on function public.mark_intro_started() from public, anon;
revoke all on function public.mark_intro_finished() from public, anon;
grant execute on function public.mark_intro_started() to authenticated;
grant execute on function public.mark_intro_finished() to authenticated;
