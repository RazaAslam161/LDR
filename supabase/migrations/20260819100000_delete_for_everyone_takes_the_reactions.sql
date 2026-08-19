-- A message deleted for everyone leaves its reactions behind.
--
-- 20260818160000 made the RPC scrub the body so a deleted message keeps no
-- readable text anywhere. Reactions arrived after it, in a table with `on
-- delete cascade` on messages.id — but this RPC does not DELETE the message, it
-- flags it. So the reaction rows survive, and their ciphertext is still one
-- couple-key decrypt away from saying what somebody felt about a message that
-- is supposed to be gone. Same rule as the body, same place.
--
-- ADDITIVE. One `create or replace` of one function, replacing the LIVE
-- definition read back from production immediately before writing this (the
-- 20260818160000 body, verbatim) with the same body plus one guarded delete.
-- No column, table, type or policy changes.
--
-- THIS FILE IS ALSO THE ROLLBACK ORDER FOR 20260819090000. That migration's
-- header says its own undo is `drop table public.message_reactions`, and a
-- PL/pgSQL body is not a tracked dependency — so dropping the table while this
-- definition is live leaves every "delete for everyone" raising 42P01, which
-- takes the body scrub down with it in the same transaction. Restore the
-- function to the definition below FIRST, then drop the table.
--
-- ROLLBACK, written before the forward change was applied — the exact
-- 20260818160000 definition, which is what production held:
--
--   create or replace function public.delete_message_for_everyone(p_message_id uuid)
--   returns void language plpgsql security definer set search_path = public as $rb$
--   declare
--     v_image text; v_voice text; v_video text; v_file text;
--   begin
--     update public.messages
--        set deleted_for_everyone = true, deleted_at = now(),
--            body = null, body_cipher = null, body_nonce = null
--      where id = p_message_id and sender_id = auth.uid()
--     returning image_path, voice_path, video_path, file_path
--          into v_image, v_voice, v_video, v_file;
--     insert into public.storage_reap (bucket_id, name)
--     select o.bucket_id, o.name
--       from storage.objects o
--      where (o.bucket_id = 'couple_media'
--               and o.name in (v_image, v_voice,
--                              regexp_replace(v_image, '([^/]*)$', 'thumb/\1')))
--         or (o.bucket_id = 'couple_intimate'
--               and o.name in (v_video,
--                              regexp_replace(v_video, '([^/]*)$', 'thumb/\1')))
--         or (o.bucket_id = 'couple_files'    and o.name = v_file)
--     on conflict do nothing;
--   end $rb$;
--
-- A SECOND RUN IS A NO-OP: `create or replace` of an identical body, and the
-- backfill below is a delete of rows that are already gone.

create or replace function public.delete_message_for_everyone(p_message_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_image text; v_voice text; v_video text; v_file text;
begin
  update public.messages
     set deleted_for_everyone = true, deleted_at = now(),
         body = null, body_cipher = null, body_nonce = null
   where id = p_message_id and sender_id = auth.uid()
  returning image_path, voice_path, video_path, file_path
       into v_image, v_voice, v_video, v_file;

  -- Only when the UPDATE above actually matched. This function is SECURITY
  -- DEFINER, so an unguarded delete would let anyone who can call it erase the
  -- reactions on any message id they can guess — the sender_id check in the
  -- UPDATE is the only authorisation in here, and `found` is how this
  -- statement inherits it.
  if found then
    delete from public.message_reactions where message_id = p_message_id;
  end if;

  insert into public.storage_reap (bucket_id, name)
  select o.bucket_id, o.name
    from storage.objects o
   where (o.bucket_id = 'couple_media'
            and o.name in (v_image, v_voice,
                           regexp_replace(v_image, '([^/]*)$', 'thumb/\1')))
      or (o.bucket_id = 'couple_intimate'
            and o.name in (v_video,
                           regexp_replace(v_video, '([^/]*)$', 'thumb/\1')))
      or (o.bucket_id = 'couple_files'    and o.name = v_file)
  on conflict do nothing;
end $$;

-- Anything already deleted before this landed. Reports what it touched rather
-- than running silently: 0 on a fleet that has not reacted yet is the expected
-- answer, and it should be said out loud rather than assumed.
do $$
declare v_n bigint;
begin
  delete from public.message_reactions r
   using public.messages m
   where m.id = r.message_id and m.deleted_for_everyone;
  get diagnostics v_n = row_count;
  raise notice 'delete_for_everyone reaction backfill: % rows removed', v_n;
end $$;
