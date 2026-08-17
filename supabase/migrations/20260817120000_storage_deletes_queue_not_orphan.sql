-- Every "delete media" promise in the app was a no-op, and the breakup purge
-- was a bomb.
--
-- Root cause, one sentence: four functions run `delete from storage.objects`,
-- which storage.protect_delete() rejects with 42501 on EVERY statement (the
-- trigger is statement-level — it fires even on zero matching rows); three of
-- them swallow the error (`exception when others then null` — permanent
-- silent no-op), and prune_dissolved_couples has no handler, so the first
-- dissolved couple past 30 days aborts the nightly cron wholesale and rolls
-- back the couples delete with it. Proven live 2026-08-17:
--   delete from storage.objects where false;
--   → ERROR 42501: Direct deletion from storage tables is not allowed.
-- And even where the trigger let it through, 20260601007500's finding stands:
-- deleting the row orphans the physical bytes — it never was a delete.
--
-- The fix is the pattern delete_my_account already uses (20260601007500):
-- queue (bucket_id, name) into public.storage_reap; the hourly
-- drain-storage-reap cron pokes the reap-storage edge function, which deletes
-- through the Storage API — row AND bytes. The silent exception blocks are
-- removed: a failed queue insert now fails the RPC loudly, in the same
-- transaction as the row change, so no partial state.
--
-- Members of the class (found by scanning pg_proc for the statement, not by
-- fixing the reported instance):
--   delete_message_for_everyone  — swallowed no-op since shipped
--   clear_conversation_everyone  — swallowed no-op since shipped
--   clear_body_photo             — swallowed no-op since shipped
--   prune_dissolved_couples      — latent nightly abort (0 dissolved couples
--                                  today, deterministic once one exists)
--
-- Second run: no-op (create table if not exists + create or replace).
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
-- Restore the four bodies below, captured verbatim from production
-- (pg_get_functiondef, 2026-08-17) before this migration replaced them:
--
--   create or replace function public.delete_message_for_everyone(p_message_id uuid)
--   returns void language plpgsql security definer set search_path to 'public' as $rollback$
--   declare
--     v_image text; v_voice text; v_video text; v_file text;
--   begin
--     update public.messages
--        set deleted_for_everyone = true, deleted_at = now()
--      where id = p_message_id and sender_id = auth.uid()
--     returning image_path, voice_path, video_path, file_path
--          into v_image, v_voice, v_video, v_file;
--     begin
--       delete from storage.objects
--        where (bucket_id = 'couple_media'    and name in (v_image, v_voice))
--           or (bucket_id = 'couple_intimate' and name = v_video)
--           or (bucket_id = 'couple_files'    and name = v_file);
--     exception when others then null;
--     end;
--   end; $rollback$;
--
--   create or replace function public.clear_conversation_everyone()
--   returns void language plpgsql security definer set search_path to 'public' as $rollback$
--   declare
--     v_couple_id uuid;
--   begin
--     select couple_id into v_couple_id from public.profiles where id = auth.uid();
--     if v_couple_id is null then raise exception 'not_paired'; end if;
--     begin
--       delete from storage.objects o
--        using public.messages m
--        where m.couple_id = v_couple_id
--          and ((o.bucket_id = 'couple_media'
--                 and o.name in (m.image_path, m.voice_path))
--            or (o.bucket_id = 'couple_intimate' and o.name = m.video_path)
--            or (o.bucket_id = 'couple_files'    and o.name = m.file_path));
--     exception when others then null;
--     end;
--     delete from public.messages where couple_id = v_couple_id;
--   end; $rollback$;
--
--   create or replace function public.clear_body_photo(p_target uuid)
--   returns void language plpgsql security definer set search_path to 'public' as $rollback$
--   declare
--     v_couple uuid := public.current_user_couple_id();
--     v_path   text;
--   begin
--     if v_couple is null then raise exception 'no_couple'; end if;
--     if not exists (
--       select 1 from public.profiles where id = p_target and couple_id = v_couple
--     ) then
--       raise exception 'not_in_couple';
--     end if;
--     select body_photo_path into v_path from public.presence where user_id = p_target;
--     update public.presence
--        set body_photo_path = null, updated_at = now()
--      where user_id = p_target and couple_id = v_couple;
--     if v_path is not null then
--       begin
--         delete from storage.objects
--          where bucket_id = 'couple_intimate' and name = v_path;
--       exception when others then null;
--       end;
--     end if;
--   end; $rollback$;
--
--   create or replace function public.prune_dissolved_couples()
--   returns void language plpgsql security definer set search_path to 'public' as $rollback$
--   declare v_ids uuid[];
--   begin
--     select coalesce(array_agg(id), '{}') into v_ids
--       from public.couples
--      where dissolved_at is not null
--        and dissolved_at < now() - interval '30 days'
--        and not exists (select 1 from public.profiles p where p.couple_id = couples.id);
--     if array_length(v_ids, 1) is null then return; end if;
--     delete from storage.objects
--      where bucket_id in ('couple_media','couple_intimate','capsule-media',
--                          'couple_files')
--        and (storage.foldername(name))[1] = any (select unnest(v_ids)::text);
--     delete from public.couples where id = any (v_ids);
--   end $rollback$;
-- ───────────────────────────────────────────────────────────────────────────

-- Staging never received 20260601007000's queue table (drift found
-- 2026-08-17); a fresh bootstrap gets it from 007000 and this is a no-op.
create table if not exists public.storage_reap (
  bucket_id text not null, name text not null, queued_at timestamptz not null default now(),
  primary key (bucket_id, name)
);
alter table public.storage_reap enable row level security;   -- no policies: nobody but DEFINER
revoke all on public.storage_reap from anon, authenticated;

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
   where (o.bucket_id = 'couple_media'    and o.name in (v_image, v_voice))
      or (o.bucket_id = 'couple_intimate' and o.name = v_video)
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
            and o.name in (m.image_path, m.voice_path))
      or (o.bucket_id = 'couple_intimate' and o.name = m.video_path)
      or (o.bucket_id = 'couple_files'    and o.name = m.file_path)
  on conflict do nothing;

  delete from public.messages where couple_id = v_couple_id;
end $fn$;

create or replace function public.clear_body_photo(p_target uuid)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_couple uuid := public.current_user_couple_id();
  v_path   text;
begin
  if v_couple is null then raise exception 'no_couple'; end if;
  -- The target must belong to the caller's couple (self or partner).
  if not exists (
    select 1 from public.profiles where id = p_target and couple_id = v_couple
  ) then
    raise exception 'not_in_couple';
  end if;
  select body_photo_path into v_path from public.presence where user_id = p_target;
  update public.presence
     set body_photo_path = null, updated_at = now()
   where user_id = p_target and couple_id = v_couple;
  -- Queue the object so the reaper erases it and no signed URL can be minted.
  if v_path is not null then
    insert into public.storage_reap (bucket_id, name)
    select o.bucket_id, o.name
      from storage.objects o
     where o.bucket_id = 'couple_intimate' and o.name = v_path
    on conflict do nothing;
  end if;
end; $fn$;

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

  -- Both shapes, as delete_my_account does: chat media by message columns,
  -- everything else by the couple's folder prefix.
  insert into public.storage_reap (bucket_id, name)
  select o.bucket_id, o.name
    from storage.objects o
    join public.messages m on m.couple_id = any (v_ids)
   where (o.bucket_id = 'couple_media'
            and o.name in (m.image_path, m.voice_path))
      or (o.bucket_id = 'couple_intimate' and o.name = m.video_path)
      or (o.bucket_id = 'couple_files'    and o.name = m.file_path)
  on conflict do nothing;

  insert into public.storage_reap (bucket_id, name)
  select o.bucket_id, o.name
    from storage.objects o
   where o.bucket_id in ('couple_media','couple_intimate','capsule-media',
                         'couple_files')
     and (storage.foldername(o.name))[1] = any (select unnest(v_ids)::text)
  on conflict do nothing;

  delete from public.couples where id = any (v_ids);
end $fn$;
