-- Survives a reinstall without giving the server the key.
--
-- The X25519 private key lives in FlutterSecureStorage, which Android wipes on
-- uninstall. Every reinstall therefore minted a fresh keypair, changed the ECDH
-- shared secret, and permanently orphaned every row encrypted under the old one
-- — the SecretBoxAuthenticationError showing on memory threads, fantasy jar and
-- the vault tiles. Nothing was corrupted; the key that opened it was destroyed
-- by the operating system, and the app never noticed.
--
-- What is stored is the seed SEALED under a key derived from the user's own
-- password (HKDF over password + per-user random salt, then XChaCha20-
-- Poly1305). The server holds ciphertext, a salt and a nonce. It never receives
-- the password — Supabase keeps only its hash — so it cannot derive the
-- wrapping key or read the seed. The end-to-end property is intact.
--
-- Own row only, and deliberately not readable by the partner. They could not
-- open it, but a wrapped blob is exactly what makes an offline dictionary
-- attack against a password possible.
create table if not exists public.key_escrow (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  wrapped_seed bytea not null,
  salt         bytea not null,
  nonce        bytea not null,
  updated_at   timestamptz not null default now()
);

alter table public.key_escrow enable row level security;
revoke all on public.key_escrow from anon;

create policy key_escrow_own_select on public.key_escrow
  for select using (user_id = (select auth.uid()));
create policy key_escrow_own_upsert on public.key_escrow
  for insert with check (user_id = (select auth.uid()));
create policy key_escrow_own_update on public.key_escrow
  for update using (user_id = (select auth.uid()))
           with check (user_id = (select auth.uid()));

comment on table public.key_escrow is
  'Password-wrapped X25519 seed, so reinstalling the app does not destroy every encrypted memory. Server-opaque: ciphertext and salt only, never the password.';
