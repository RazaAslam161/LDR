-- A new account could never produce an invite code.
--
-- handle_new_user() inserts a profile with couple_id NULL. Nothing then ever
-- creates the couple: SupabaseRepository.createCouple() exists and has zero
-- call sites, and couple_page._create() calls create_pairing_invite directly.
-- That function opens with
--
--     select couple_id into v_couple from public.profiles where id = v_uid;
--     if v_couple is null then raise exception 'no_couple'; end if;
--
-- so "Create and get a code" on a fresh account raised no_couple, which the
-- client renders as "something went wrong". Both accounts made on 2026-08-12
-- are sitting with couple_id null right now. Onboarding has been closed to
-- every new user; the twelve existing couples predate whatever removed the
-- call.
--
-- Fixed here rather than in the app on purpose. This fleet is sideloaded and
-- has no update channel, so a client-side fix would strand every handset
-- already carrying build 9 or 10 — and those are the builds people have. A
-- server-side fix reaches them without anyone installing anything.
--
-- create_couple() is already idempotent (it returns the existing couple when
-- the caller has one), so this is a reuse rather than a second implementation
-- of the same insert.

create or replace function public.create_pairing_invite(p_ttl_minutes integer default 60)
returns public.pairing_invites
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_uid uuid := auth.uid();
  v_couple uuid;
  v_code text;
  v_row public.pairing_invites;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select couple_id into v_couple from public.profiles where id = v_uid;

  -- Asking for an invite IS the intent to start a couple. Requiring a separate
  -- create_couple call bought nothing except a failure mode, since there is no
  -- state in which a user wants a code but does not want the couple behind it.
  if v_couple is null then
    select id into v_couple
    from public.create_couple(coalesce(
      (select timezone from public.profiles where id = v_uid), 'UTC'
    ));
  end if;

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
end $function$;

comment on function public.create_pairing_invite(integer) is
  'Mints a pairing code, creating the caller''s couple if they do not have one '
  'yet. A fresh account has couple_id null and nothing else in the app ever '
  'fills it, so without this every new signup dead-ended at "something went '
  'wrong" on the first screen it reached.';
