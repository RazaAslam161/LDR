-- ───────────────────────────────────────────────────────────────────────────
-- Miles — partner public keys (E2EE key exchange)
-- Safe to store in plaintext: these are PUBLIC keys only.
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.partner_keys (
  user_id     uuid primary key references public.profiles(id) on delete cascade,
  public_key  text not null,                 -- X25519 public key, base64
  updated_at  timestamptz not null default now()
);

alter table public.partner_keys enable row level security;

-- A user can read any partner_key tied to their couple (so they can derive
-- the shared key), but only insert/update their own.
drop policy if exists "partner_keys_select_member" on public.partner_keys;
create policy "partner_keys_select_member" on public.partner_keys
  for select using (
    user_id in (
      select p.id from public.profiles p
      where p.couple_id = public.current_user_couple_id()
    )
  );

drop policy if exists "partner_keys_insert_self" on public.partner_keys;
create policy "partner_keys_insert_self" on public.partner_keys
  for insert with check (user_id = auth.uid());

drop policy if exists "partner_keys_update_self" on public.partner_keys;
create policy "partner_keys_update_self" on public.partner_keys
  for update using (user_id = auth.uid())
  with check (user_id = auth.uid());
