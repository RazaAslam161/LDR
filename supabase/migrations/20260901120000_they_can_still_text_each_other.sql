-- The doorstep's phones: while the ceremony holds, the two of them can still
-- text each other — in the scene, through their characters' phones.
--
-- ROLLBACK (written before the forward change, per standing rule):
--   drop function if exists public.unlink_send_message(bytea, bytea);
--   drop table if exists public.unlink_messages;
--
-- SHAPE: E2EE exactly like chat and the farewell note — cipher + nonce bytea,
-- the server never sees plaintext. Insert-only through a SECURITY DEFINER RPC
-- that derives the couple from auth.uid() (a write must prove the couple it
-- claims, 20260829145343) and requires a LIVE ceremony: this channel exists
-- only while the doorstep does. The farewell note (couple_unlink.note_*) is
-- untouched — that is the goodbye letter; these are the words before it.
--
-- REALTIME: this table is deliberately NOT added to the publication. The
-- knock is a broadcast on the existing unlink scene channel plus the screen's
-- 15s poll; the bytes ALWAYS arrive via PostgREST (§208 — realtime
-- double-hex-encodes bytea; nothing may parse a payload).
--
-- Messages from an earlier ceremony of the same couple are excluded by the
-- CLIENT filtering created_at >= the row's started_at; a later cron may prune
-- rows older than the dissolution window. A second run of this file: no-op.

create table if not exists public.unlink_messages (
  id          bigint generated always as identity primary key,
  couple_id   uuid not null references public.couples(id) on delete cascade,
  sender      uuid not null references public.profiles(id) on delete set null,
  cipher      bytea not null,
  nonce       bytea not null,
  created_at  timestamptz not null default now(),
  constraint unlink_messages_cipher_size
    check (octet_length(cipher) <= 8192),
  constraint unlink_messages_nonce_size
    check (octet_length(nonce) between 12 and 48)
);

create index if not exists unlink_messages_couple_idx
  on public.unlink_messages (couple_id, id desc);

alter table public.unlink_messages enable row level security;

revoke all on public.unlink_messages from anon, authenticated;
grant select on public.unlink_messages to authenticated;

drop policy if exists unlink_messages_select_member on public.unlink_messages;
create policy unlink_messages_select_member on public.unlink_messages
  for select using (couple_id = (select public.current_user_couple_id()));

comment on table public.unlink_messages is
  'E2EE texts between the two of them DURING an unlink ceremony only. '
  'Written solely by unlink_send_message(); read via RLS select. Bytes are '
  'ciphertext+nonce under the couple key; the server holds no plaintext.';

create or replace function public.unlink_send_message(
  p_cipher bytea,
  p_nonce bytea
)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_cipher is null or p_nonce is null then
    raise exception 'message_halves_missing';
  end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then raise exception 'no_couple'; end if;
  -- The phone exists only while the doorstep does.
  if not exists (
    select 1 from public.couple_unlink where couple_id = v_couple
  ) then
    raise exception 'no_ceremony';
  end if;
  insert into public.unlink_messages (couple_id, sender, cipher, nonce)
  values (v_couple, v_uid, p_cipher, p_nonce);
end;
$fn$;

revoke all on function public.unlink_send_message(bytea, bytea)
  from public, anon;
grant execute on function public.unlink_send_message(bytea, bytea)
  to authenticated;
