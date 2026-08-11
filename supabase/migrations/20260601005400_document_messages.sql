-- ───────────────────────────────────────────────────────────────────────────
-- Miles — "there is no option of send documents , files or anything else in
-- the app."
--
-- A document is not a photo and does not belong in couple_media: that bucket's
-- allowed_mime_types is a whitelist of images and audio, chosen deliberately
-- when every bucket was closed, and widening it to accept a PDF would widen it
-- for the 255 photos too. Files get their own bucket, keyed the same way — one
-- folder per couple — so the same storage RLS shape applies and the same
-- lifecycle sweeps can find them.
--
-- ON MIME TYPES: couple_files has no whitelist, and that is a decision rather
-- than an oversight. The point of the feature is arbitrary files, and a
-- whitelist here would be theatre in any case — allowed_mime_types is checked
-- against the Content-Type the CLIENT declares, so anything excluded is one
-- 'application/octet-stream' away from being allowed. What actually bounds the
-- abuse the bucket audit named is what is kept: a hard 25MB per object, a
-- private bucket, 24-hour signed URLs, and an insert policy that only lets you
-- write inside your own couple's folder.
--
-- LIFECYCLE: the three sweeps below are rewritten only to name the new bucket.
-- A bucket that no delete path knows about is the "a breakup left the
-- photographs on disk forever" bug again, with a new prefix.
-- ───────────────────────────────────────────────────────────────────────────

-- The name lives in `body`, not in a column of its own, so that a build
-- already in the field — which has no idea what kind='file' is and falls
-- through to rendering the body — shows "quarterly-report.pdf" rather than an
-- empty bubble. This fleet has no update channel; the old clients are the
-- majority for as long as it takes people to sideload.
alter table public.messages
  add column if not exists file_path text,
  add column if not exists file_size bigint;

insert into storage.buckets (id, name, public, file_size_limit)
values ('couple_files', 'couple_files', false, 26214400)
on conflict (id) do update
  set public = false,
      file_size_limit = 26214400,
      allowed_mime_types = null;

drop policy if exists couple_files_read on storage.objects;
create policy couple_files_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'couple_files'
    and (storage.foldername(name))[1] = (select public.current_user_couple_id())::text
  );

drop policy if exists couple_files_upload on storage.objects;
create policy couple_files_upload on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'couple_files'
    and (storage.foldername(name))[1] = (select public.current_user_couple_id())::text
  );

drop policy if exists couple_files_delete on storage.objects;
create policy couple_files_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'couple_files'
    and (storage.foldername(name))[1] = (select public.current_user_couple_id())::text
  );

-- ─── the sweeps ────────────────────────────────────────────────────────────

create or replace function public.delete_message_for_everyone(p_message_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_image text; v_voice text; v_video text; v_file text;
begin
  update public.messages
     set deleted_for_everyone = true, deleted_at = now()
   where id = p_message_id and sender_id = auth.uid()
  returning image_path, voice_path, video_path, file_path
       into v_image, v_voice, v_video, v_file;
  -- NULLs never match IN/=, so a text message deletes nothing here.
  begin
    delete from storage.objects
     where (bucket_id = 'couple_media'    and name in (v_image, v_voice))
        or (bucket_id = 'couple_intimate' and name = v_video)
        or (bucket_id = 'couple_files'    and name = v_file);
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
         or (o.bucket_id = 'couple_intimate' and o.name = m.video_path)
         or (o.bucket_id = 'couple_files'    and o.name = m.file_path));
  exception when others then null;
  end;

  delete from public.messages where couple_id = v_couple_id;
end; $$;
revoke execute on function public.clear_conversation_everyone() from public, anon;
grant  execute on function public.clear_conversation_everyone() to authenticated;

create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public as $$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
  v_others int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;

  if v_couple is not null then
    select count(*) into v_others
      from public.profiles where couple_id = v_couple and id <> v_uid;

    -- Media is shared between partners, so it can only go when the last
    -- member does. Best-effort: a storage hiccup must not strand the user
    -- with an account they asked to delete and cannot delete.
    if v_others = 0 then
      begin
        delete from storage.objects o
         using public.messages m
         where m.couple_id = v_couple
           and ((o.bucket_id = 'couple_media'
                  and o.name in (m.image_path, m.voice_path))
             or (o.bucket_id = 'couple_intimate' and o.name = m.video_path)
             or (o.bucket_id = 'couple_files'    and o.name = m.file_path));
        delete from storage.objects
         where bucket_id in ('couple_media', 'couple_intimate', 'capsule-media',
                             'couple_files')
           and (storage.foldername(name))[1] = v_couple::text;
      exception when others then null;
      end;
    end if;

    -- Unlink first so the couple row is free to go once it is empty. The
    -- guard trigger only refuses client-role writes; this runs as owner.
    update public.profiles set couple_id = null where id = v_uid;
    if v_others = 0 then
      delete from public.messages where couple_id = v_couple;
      delete from public.couples  where id = v_couple;
    end if;
  end if;

  -- Cascades to public.profiles via profiles.id -> auth.users(id) on delete
  -- cascade, and from there to every table keyed on the profile.
  delete from auth.users where id = v_uid;
end; $$;
revoke execute on function public.delete_my_account() from public, anon;
grant  execute on function public.delete_my_account() to authenticated;

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

  -- Media first: it is the bulk, and it is the intimate part.
  delete from storage.objects
   where bucket_id in ('couple_media','couple_intimate','capsule-media',
                       'couple_files')
     and (storage.foldername(name))[1] = any (select unnest(v_ids)::text);

  -- Then the couple. Every couple-scoped table cascades from here — the same
  -- foreign keys account deletion depends on — so this needs no table list that
  -- would rot the next time a feature adds one.
  delete from public.couples where id = any (v_ids);
end $fn$;

revoke execute on function public.prune_dissolved_couples() from public, anon, authenticated;
