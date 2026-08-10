-- ───────────────────────────────────────────────────────────────────────────
-- Miles — joining a couple was the least defended thing in the app, and the
-- most valuable. It grants every message, every intimate photo, live location.
--
-- TWO PROBLEMS, both invisible at two users and certain at thousands:
--
-- 1. The code space was 16^6, not 36^6. Codes come from gen_random_uuid()
--    hex — sixteen symbols, not thirty-six — so six characters is about 16.7
--    MILLION, not two billion.
--
-- 2. redeem_pairing_invite counted nothing. A caller could guess forever.
--
-- The attack is not guessing one couple's code. It is guessing ANY LIVE ONE.
-- With a few hundred invites outstanding across a userbase, each attempt is
-- roughly 1 in 30,000, so a plain loop puts a stranger inside somebody's
-- relationship within the hour. With two users there are no live invites to
-- hit and the whole thing looks like a non-issue, which is exactly why it
-- survived.
--
-- Both fixes are server-side; no client changes, so no version-gate step. The
-- entry field already accepts eight characters, and six-character invites that
-- are already out keep working until they expire.
--
-- Verified on staging with a throwaway tenant rather than by reading the code:
-- ten failures inside the window, limiter trips true. Probe deleted after.
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.pairing_attempts (
  id           bigserial primary key,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  attempted_at timestamptz not null default now(),
  ok           boolean not null
);

create index if not exists pairing_attempts_user_time_idx
  on public.pairing_attempts (user_id, attempted_at desc);

alter table public.pairing_attempts enable row level security;
-- No policy, and no grants: only the SECURITY DEFINER redeem function touches
-- this. A user who can read or clear their own failure count has no limiter.
revoke all on public.pairing_attempts from anon, authenticated;

-- 16^8 = 4.3 billion, a 256x larger keyspace, for everything minted from now on.
create or replace function public.create_pairing_invite(p_ttl_minutes integer default 60)
returns public.pairing_invites language plpgsql security definer
set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_couple uuid;
  v_code text;
  v_row public.pairing_invites;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then raise exception 'no_couple'; end if;
  loop
    v_code := upper(substr(replace(gen_random_uuid()::text,'-',''), 1, 8));
    exit when not exists (select 1 from public.pairing_invites where code = v_code);
  end loop;
  insert into public.pairing_invites (code, couple_id, created_by, expires_at)
  values (v_code, v_couple, v_uid,
          now() + make_interval(mins => greatest(coalesce(p_ttl_minutes, 60), 1)))
  returning * into v_row;
  return v_row;
end $fn$;

revoke execute on function public.create_pairing_invite(integer) from public, anon;
grant execute on function public.create_pairing_invite(integer) to authenticated;

-- Ten wrong codes in fifteen minutes is not somebody typing from a screenshot,
-- it is a script. A real join is one attempt, occasionally two.
--
-- Counted per authenticated user, the only identity Postgres has here. An
-- attacker can mint accounts, so this is not a wall — it turns one cheap
-- infinite loop into "make a new account every ten guesses", which pushes the
-- cost onto signup, where the platform's own rate limits and email
-- confirmation live. Removing the free unlimited oracle is the goal.
--
-- The three failure cases now share ONE message. Distinct errors told a
-- guesser which codes exist but are spent — a free map of the keyspace.
create or replace function public.redeem_pairing_invite(p_code text)
returns public.couples language plpgsql security definer
set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_clean text := upper(regexp_replace(coalesce(p_code,''), '\s', '', 'g'));
  v_invite public.pairing_invites;
  v_couple public.couples;
  v_my_couple uuid;
  v_count int;
  v_fails int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select count(*) into v_fails
    from public.pairing_attempts
   where user_id = v_uid and not ok
     and attempted_at > now() - interval '15 minutes';
  if v_fails >= 10 then raise exception 'too_many_attempts'; end if;

  select couple_id into v_my_couple from public.profiles where id = v_uid;
  select * into v_invite from public.pairing_invites where code = v_clean;

  if not found or v_invite.consumed_at is not null or v_invite.expires_at < now() then
    insert into public.pairing_attempts (user_id, ok) values (v_uid, false);
    raise exception 'invalid_code';
  end if;

  if v_my_couple = v_invite.couple_id then
    insert into public.pairing_attempts (user_id, ok) values (v_uid, true);
    select * into v_couple from public.couples where id = v_invite.couple_id;
    return v_couple;
  end if;

  select count(*) into v_count from public.profiles where couple_id = v_invite.couple_id;
  if v_count >= 2 then
    insert into public.pairing_attempts (user_id, ok) values (v_uid, false);
    raise exception 'couple_full';
  end if;

  update public.profiles set couple_id = v_invite.couple_id where id = v_uid;
  update public.pairing_invites set consumed_at = now(), consumed_by = v_uid
   where code = v_clean;
  insert into public.pairing_attempts (user_id, ok) values (v_uid, true);

  select * into v_couple from public.couples where id = v_invite.couple_id;
  return v_couple;
end $fn$;

revoke execute on function public.redeem_pairing_invite(text) from public, anon;
grant execute on function public.redeem_pairing_invite(text) to authenticated;

-- One row per guess, at a rate the attacker chooses. It needs a bound.
create or replace function public.prune_pairing_attempts()
returns void language sql security definer set search_path = public as $fn$
  delete from public.pairing_attempts where attempted_at < now() - interval '1 day';
$fn$;
revoke execute on function public.prune_pairing_attempts() from public, anon, authenticated;

do $do$
begin
  if exists (select 1 from pg_extension where extname='pg_cron') then
    if exists (select 1 from cron.job where jobname='prune-pairing-attempts') then
      perform cron.unschedule('prune-pairing-attempts');
    end if;
    perform cron.schedule('prune-pairing-attempts', '23 3 * * *',
      'select public.prune_pairing_attempts()');
  end if;
end $do$;
