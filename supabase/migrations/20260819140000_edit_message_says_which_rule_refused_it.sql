-- Recovered from the production ledger on 2026-08-23; never committed.
--
-- Applied to prod `sopictusdonlvuezmfep` as version 20260819161249 on
-- 2026-08-19 16:12 UTC, then lost with the disk that held the working
-- tree. The body below is byte-identical to that ledger's stored
-- statements, md5 verified. The explanatory comment this repo's style
-- asks for is absent because it was never in the ledger: these were
-- applied as bare SQL, so whatever prose sat above them died with the
-- disk.
--
-- Renumbered to 20260819140000 so replay order stays correct against the
-- slot scheme the other files in this directory use.

create index if not exists messages_sender_edited_idx
  on public.messages (sender_id, edited_at desc)
  where edited_at is not null;

create or replace function public.edit_message(
  p_message_id uuid,
  p_body       text,
  p_cipher     bytea,
  p_nonce      bytea
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sender     uuid;
  v_couple     uuid;
  v_kind       text;
  v_deleted    boolean;
  v_created    timestamptz;
  v_edited     timestamptz;
  v_had_cipher boolean;
  v_mine       uuid := auth.uid();
  v_my_couple  uuid;
  v_recent     int;
begin
  select sender_id, couple_id, kind, deleted_for_everyone,
         created_at, edited_at, body_cipher is not null
    into v_sender, v_couple, v_kind, v_deleted,
         v_created, v_edited, v_had_cipher
    from public.messages
   where id = p_message_id;

  if v_sender is null or v_sender is distinct from v_mine then
    return 'not_found';
  end if;

  v_my_couple := public.current_user_couple_id();
  if v_couple is distinct from v_my_couple then
    return 'wrong_couple';
  end if;
  if v_kind is distinct from 'text' then
    return 'not_text';
  end if;
  if v_deleted then
    return 'deleted';
  end if;
  if v_created <= now() - interval '30 minutes' then
    return 'too_late';
  end if;
  if v_edited is not null and v_edited >= now() - interval '3 seconds' then
    return 'too_soon';
  end if;
  if p_cipher is null and v_had_cipher then
    return 'no_cipher';
  end if;

  select count(*) into v_recent
    from public.messages
   where sender_id = v_mine
     and edited_at > now() - interval '1 hour';
  if v_recent >= 60 then
    return 'too_many';
  end if;

  update public.messages
     set body        = p_body,
         body_cipher = p_cipher,
         body_nonce  = p_nonce,
         edited_at   = now()
   where id = p_message_id
     and sender_id = v_mine
     and couple_id = v_my_couple
     and kind = 'text'
     and not deleted_for_everyone
     and created_at > now() - interval '30 minutes'
     and (p_cipher is not null or body_cipher is null)
     and (edited_at is null or edited_at < now() - interval '3 seconds');

  if found then
    return 'ok';
  end if;
  return 'refused';
end $$;

revoke all on function public.edit_message(uuid, text, bytea, bytea) from public;
revoke all on function public.edit_message(uuid, text, bytea, bytea) from anon;
grant execute on function public.edit_message(uuid, text, bytea, bytea) to authenticated;
