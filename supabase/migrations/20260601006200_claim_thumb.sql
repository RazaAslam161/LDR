-- Lets a device flip has_thumb after it has healed a legacy row by generating
-- and uploading the thumbnail sibling the original never got.
--
-- Needed because 20260601003200 replaced messages_update_member with
-- messages_update_own (sender_id = auth.uid()), so without this each partner
-- could only heal their own half of the history and every photo the other
-- person sent would keep decoding from the original forever.
--
-- Deliberately narrow: one boolean, one row, inside the caller's own couple,
-- and only false -> true. It cannot touch a body, a path or a deletion flag, so
-- it is not a widening of messages_update_own by the back door.
--
-- Storage needs no new policy: every couple_media policy keys on
-- (storage.foldername(name))[1] = current_user_couple_id()::text, and
-- Thumbnails.pathFor keeps the couple id as the first segment, so either
-- partner may already write the sibling object.
create or replace function public.claim_thumb(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  update public.messages
     set has_thumb = true
   where id = p_message_id
     and couple_id = (select public.current_user_couple_id())
     and has_thumb = false;
end $function$;

revoke all on function public.claim_thumb(uuid) from public, anon;
grant execute on function public.claim_thumb(uuid) to authenticated;

comment on function public.claim_thumb(uuid) is
  'Marks a message as having a thumbnail sibling, after the client has uploaded one. Callable only by a member of the row''s own couple, and only false -> true.';
