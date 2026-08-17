-- 20260817120000 taught chat deletion to actually erase — and thereby created
-- the orphan it was written to end.
--
-- Root cause, one sentence: every chat image and video has a sibling
-- thumbnail at a DIFFERENT object name (Thumbnails.pathFor inserts `thumb/`
-- before the basename: `<couple>/img_x.jpg` → `<couple>/thumb/img_x.jpg`,
-- same bucket), so a queue keyed on the message's path columns reaps the
-- original and leaves the thumb — and clear_conversation_everyone deletes the
-- message rows in the same transaction, after which the thumb's name exists
-- in no row anywhere: unreachable, unbilled-for by nobody, impossible to
-- erase. Harmless before 20260817120000 only because nothing was deleted at
-- all.
--
-- Fix: queue the thumb beside the original by deriving its name in SQL
-- (regexp_replace inserts `thumb/` before the last path segment — the exact
-- transform thumbnails.dart applies). Matching against storage.objects means
-- a message that never got a thumb (has_thumb false, legacy rows) queues
-- nothing extra.
--
-- Also: prune_dissolved_couples loses 20260817120000's message-join insert.
-- Chat media paths are couple-prefixed (`$coupleId/...`, chat_repository
-- upload paths), so the folder-prefix sweep already catches them AND their
-- thumbs; the join was a nightly unindexed scan of storage.objects that could
-- never add a row. clear_body_photo is untouched — body photos have no thumbs.
--
-- Second run: no-op (create or replace only).
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
-- Restore the 20260817120000 bodies (its file holds them in full); the diff
-- is only the thumb terms in the two WHERE clauses and prune's extra insert.
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.delete_message_for_everyone(p_message_id uuid)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_image text; v_voice text; v_video text; v_file text;
begin
  update public.messages
     set deleted_for_everyone = true, deleted_at = now()
   where id = p_message_id and sender_id = auth.uid()
  returning image_path, voice_path, video_path, file_path
       into v_image, v_voice, v_video, v_file;

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
end $fn$;

create or replace function public.clear_conversation_everyone()
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_couple_id uuid;
begin
  select couple_id into v_couple_id from public.profiles where id = auth.uid();
  if v_couple_id is null then raise exception 'not_paired'; end if;

  insert into public.storage_reap (bucket_id, name)
  select o.bucket_id, o.name
    from storage.objects o
    join public.messages m on m.couple_id = v_couple_id
   where (o.bucket_id = 'couple_media'
            and o.name in (m.image_path, m.voice_path,
                           regexp_replace(m.image_path, '([^/]*)$', 'thumb/\1')))
      or (o.bucket_id = 'couple_intimate'
            and o.name in (m.video_path,
                           regexp_replace(m.video_path, '([^/]*)$', 'thumb/\1')))
      or (o.bucket_id = 'couple_files'    and o.name = m.file_path)
  on conflict do nothing;

  delete from public.messages where couple_id = v_couple_id;
end $fn$;

create or replace function public.prune_dissolved_couples()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_ids uuid[];
begin
  select coalesce(array_agg(id), '{}') into v_ids
    from public.couples
   where dissolved_at is not null
     and dissolved_at < now() - interval '30 days'
     and not exists (select 1 from public.profiles p where p.couple_id = couples.id);

  if array_length(v_ids, 1) is null then return; end if;

  -- The prefix sweep alone: chat media and its thumbs are couple-prefixed
  -- (the couple id stays the first segment — thumbnails.dart relies on the
  -- same fact for storage policies), so a message join could never add a row.
  insert into public.storage_reap (bucket_id, name)
  select o.bucket_id, o.name
    from storage.objects o
   where o.bucket_id in ('couple_media','couple_intimate','capsule-media',
                         'couple_files')
     and (storage.foldername(o.name))[1] = any (select unnest(v_ids)::text)
  on conflict do nothing;

  delete from public.couples where id = any (v_ids);
end $fn$;
