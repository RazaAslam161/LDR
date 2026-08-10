-- ───────────────────────────────────────────────────────────────────────────
-- Tethered — expiring pairing invites + anniversary date. Run AFTER schema.sql.
-- Keeps the existing profiles.couple_id link; adds short-lived, single-use 6-char
-- invite codes (replacing the permanent couples.invite_code for the join flow).
-- Redemption is a SECURITY DEFINER RPC because the joiner isn't in the couple yet.
-- ───────────────────────────────────────────────────────────────────────────
alter table public.couples add column if not exists anniversary_date date;

create table if not exists public.pairing_invites (
  code        text primary key,
  couple_id   uuid not null references public.couples(id) on delete cascade,
  created_by  uuid not null references public.profiles(id) on delete cascade,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null,
  consumed_at timestamptz,
  consumed_by uuid references public.profiles(id)
);
create index if not exists pairing_invites_couple_idx on public.pairing_invites(couple_id);

alter table public.pairing_invites enable row level security;
drop policy if exists "pairing_invites_select_member" on public.pairing_invites;
create policy "pairing_invites_select_member" on public.pairing_invites
  for select using (couple_id = public.current_user_couple_id());

create or replace function public.create_pairing_invite(p_ttl_minutes int default 1440)
returns public.pairing_invites
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_couple_id uuid;
  v_code text;
  v_try int := 0;
  v_invite public.pairing_invites;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple_id from public.profiles where id = v_uid;
  if v_couple_id is null then
    insert into public.couples (invite_code, primary_tz)
      values (upper(substr(replace(gen_random_uuid()::text,'-',''),1,6)), null)
      returning id into v_couple_id;
    update public.profiles set couple_id = v_couple_id where id = v_uid;
  end if;
  loop
    v_try := v_try + 1;
    v_code := upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
    begin
      insert into public.pairing_invites (code, couple_id, created_by, expires_at)
        values (v_code, v_couple_id, v_uid, now() + make_interval(mins => p_ttl_minutes))
        returning * into v_invite;
      exit;
    exception when unique_violation then
      if v_try >= 6 then raise; end if;
    end;
  end loop;
  return v_invite;
end; $$;
revoke execute on function public.create_pairing_invite(int) from public, anon;
grant  execute on function public.create_pairing_invite(int) to authenticated;

create or replace function public.redeem_pairing_invite(p_code text)
returns public.couples
language plpgsql security definer set search_path = public as $$
declare
  v_uid uuid := auth.uid();
  v_clean text := upper(regexp_replace(coalesce(p_code,''), '\s', '', 'g'));
  v_invite public.pairing_invites;
  v_couple public.couples;
  v_count int;
  v_my_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_my_couple from public.profiles where id = v_uid;
  select * into v_invite from public.pairing_invites where code = v_clean;
  if not found then raise exception 'invalid_code'; end if;
  if v_invite.consumed_at is not null then raise exception 'already_used'; end if;
  if v_invite.expires_at < now() then raise exception 'expired'; end if;
  if v_my_couple = v_invite.couple_id then
    select * into v_couple from public.couples where id = v_invite.couple_id; return v_couple;
  end if;
  if v_my_couple is not null then raise exception 'already_paired'; end if;
  select count(*) into v_count from public.profiles where couple_id = v_invite.couple_id;
  if v_count >= 2 then raise exception 'couple_full'; end if;
  update public.profiles set couple_id = v_invite.couple_id where id = v_uid;
  update public.pairing_invites set consumed_at = now(), consumed_by = v_uid where code = v_clean;
  select * into v_couple from public.couples where id = v_invite.couple_id;
  return v_couple;
end; $$;
revoke execute on function public.redeem_pairing_invite(text) from public, anon;
grant  execute on function public.redeem_pairing_invite(text) to authenticated;
