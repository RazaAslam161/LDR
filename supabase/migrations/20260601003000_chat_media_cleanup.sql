-- ───────────────────────────────────────────────────────────────────────────
-- Miles — chat media cleanup. Run AFTER settings_and_delete.sql and
-- clear_chat_everyone.sql (replaces both delete functions).
--
-- Deleting a message removed the row and left the file: the photo stayed in
-- the bucket and a signed URL could still be minted for it. Both hard-delete
-- paths now drop the stored object too, best-effort like clear_body_photo —
-- a storage hiccup must not make the delete itself fail.
--
-- "Delete for me" deliberately does NOT touch storage: the partner still
-- sees that message.
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.delete_message_for_everyone(p_message_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_image text; v_voice text; v_video text;
begin
  update public.messages
     set deleted_for_everyone = true, deleted_at = now()
   where id = p_message_id and sender_id = auth.uid()
  returning image_path, voice_path, video_path into v_image, v_voice, v_video;
  -- NULLs never match IN/=, so a text message deletes nothing here.
  begin
    delete from storage.objects
     where (bucket_id = 'couple_media'    and name in (v_image, v_voice))
        or (bucket_id = 'couple_intimate' and name = v_video);
  exception when others then null;
  end;
end; $$;
revoke execute on function public.delete_message_for_everyone(uuid) from public, anon;
grant  execute on function public.delete_message_for_everyone(uuid) to authenticated;

create or replace function public.clear_conversation_everyone()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_couple_id uuid;
begin
  select couple_id into v_couple_id from public.profiles where id = auth.uid();
  if v_couple_id is null then raise exception 'not_paired'; end if;

  -- Files first, while the rows still say which ones are ours.
  begin
    delete from storage.objects o
     using public.messages m
     where m.couple_id = v_couple_id
       and ((o.bucket_id = 'couple_media'
              and o.name in (m.image_path, m.voice_path))
         or (o.bucket_id = 'couple_intimate' and o.name = m.video_path));
  exception when others then null;
  end;

  delete from public.messages where couple_id = v_couple_id;
end; $$;
revoke execute on function public.clear_conversation_everyone() from public, anon;
grant  execute on function public.clear_conversation_everyone() to authenticated;
