-- ───────────────────────────────────────────────────────────────────────────
-- Tethered — Private Vault (Issue 9). Run AFTER schema.sql.
-- Personal (owner-only) vault + a 4-digit PIN hashed server-side (bcrypt),
-- with a 5-try / 15-minute lockout. (Named `personal_vault_items` because the
-- couple-scoped `vault_items` already exists in the Closer module.)
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists public.vault_pin (
  user_id           uuid primary key references public.profiles(id) on delete cascade,
  pin_hash          text not null,
  biometric_enabled boolean not null default false,
  failed_attempts   int not null default 0,
  locked_until      timestamptz
);
alter table public.vault_pin enable row level security;
drop policy if exists "vault_pin_self" on public.vault_pin;
create policy "vault_pin_self" on public.vault_pin
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

create table if not exists public.personal_vault_items (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null references public.profiles(id) on delete cascade,
  type       text not null default 'note',
  content    text,
  media_url  text,
  created_at timestamptz not null default now()
);
alter table public.personal_vault_items enable row level security;
drop policy if exists "pvi_owner_only" on public.personal_vault_items;
create policy "pvi_owner_only" on public.personal_vault_items
  for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create or replace function public.set_vault_pin(p_pin text)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_pin !~ '^[0-9]{4}$' then raise exception 'invalid_pin'; end if;
  insert into public.vault_pin (user_id, pin_hash)
    values (v_uid, crypt(p_pin, gen_salt('bf')))
  on conflict (user_id) do update
    set pin_hash = excluded.pin_hash, failed_attempts = 0, locked_until = null;
end; $$;
revoke execute on function public.set_vault_pin(text) from public, anon;
grant  execute on function public.set_vault_pin(text) to authenticated;

create or replace function public.verify_vault_pin(p_pin text)
returns text language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); r public.vault_pin;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select * into r from public.vault_pin where user_id = v_uid;
  if not found then return 'no_pin'; end if;
  if r.locked_until is not null and r.locked_until > now() then return 'locked'; end if;
  if r.pin_hash = crypt(p_pin, r.pin_hash) then
    update public.vault_pin set failed_attempts = 0, locked_until = null where user_id = v_uid;
    return 'ok';
  end if;
  update public.vault_pin
     set failed_attempts = failed_attempts + 1,
         locked_until = case when failed_attempts + 1 >= 5
                             then now() + interval '15 minutes' else null end
   where user_id = v_uid;
  return 'wrong';
end; $$;
revoke execute on function public.verify_vault_pin(text) from public, anon;
grant  execute on function public.verify_vault_pin(text) to authenticated;

create or replace function public.has_vault_pin()
returns boolean language sql security definer set search_path = public as $$
  select exists(select 1 from public.vault_pin where user_id = auth.uid());
$$;
revoke execute on function public.has_vault_pin() from public, anon;
grant  execute on function public.has_vault_pin() to authenticated;
