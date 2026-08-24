-- Recovered from the production ledger on 2026-08-23; never committed.
--
-- Applied to prod `sopictusdonlvuezmfep` as version 20260819143610 on
-- 2026-08-19 14:36 UTC, then lost with the disk that held the working
-- tree. The body below is byte-identical to that ledger's stored
-- statements, md5 verified. The explanatory comment this repo's style
-- asks for is absent because it was never in the ledger: these were
-- applied as bare SQL, so whatever prose sat above them died with the
-- disk.
--
-- Renumbered to 20260819130000 so replay order stays correct against the
-- slot scheme the other files in this directory use.

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
  v_ok boolean;
  v_recent int;
begin
  select count(*) into v_recent
    from public.messages
   where sender_id = auth.uid()
     and edited_at > now() - interval '1 hour';
  if v_recent >= 60 then
    raise exception 'rate_limited' using errcode = 'PT429';
  end if;

  update public.messages
     set body       = p_body,
         body_cipher = p_cipher,
         body_nonce  = p_nonce,
         edited_at   = now()
   where id = p_message_id
     and sender_id = auth.uid()
     and couple_id = (select public.current_user_couple_id())
     and kind = 'text'
     and not deleted_for_everyone
     and created_at > now() - interval '30 minutes'
     and (p_cipher is not null or body_cipher is null)
     and (edited_at is null or edited_at < now() - interval '3 seconds');

  if found then
    return 'ok';
  end if;

  select true into v_ok
    from public.messages
   where id = p_message_id and sender_id = auth.uid();

  if v_ok is null then
    return 'not_found';
  end if;
  return 'refused';
end $$;
