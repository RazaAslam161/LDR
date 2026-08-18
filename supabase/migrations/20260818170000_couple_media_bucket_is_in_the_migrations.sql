-- §63 follow-up: the app's PRIMARY media bucket existed only in the prod
-- dashboard. couple_media (chat photos, voice notes, thumbnails) had no
-- CREATE and no storage.objects policies anywhere in 126 migration files —
-- so a rebuild from the "schema of record" produced a database whose main
-- bucket either did not exist or had no couple isolation. Prod itself was
-- verified closed (2026-08-18: three policies, all couple-scoped); this
-- writes exactly that live state down.
--
-- Everything below MIRRORS prod as read from storage.buckets/pg_policies on
-- 2026-08-18 — the size cap, the mime list, the three policies verbatim.
-- Applying to prod is a converge-to-same no-op; applying to a fresh
-- environment creates what prod already has.
--
-- Second run: no-op (upsert + drop-if-exists/create, same definitions).
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
--   None needed on prod (identical state before and after). On an
--   environment that never had the bucket: delete from storage.buckets
--   where id='couple_media' and the three policies below — but that is the
--   pre-migration broken state, not a state to return to.
-- ───────────────────────────────────────────────────────────────────────────

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('couple_media', 'couple_media', false, 26214400,
        array['image/jpeg','image/png','image/webp','image/gif',
              'audio/mp4','audio/aac','audio/mpeg','audio/ogg'])
on conflict (id) do update
   set public            = excluded.public,
       file_size_limit   = excluded.file_size_limit,
       allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "couple_media_read" on storage.objects;
create policy "couple_media_read" on storage.objects
  for select to authenticated
  using (bucket_id = 'couple_media'
     and (storage.foldername(name))[1] = (public.current_user_couple_id())::text);

drop policy if exists "couple_media_upload" on storage.objects;
create policy "couple_media_upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'couple_media'
     and (storage.foldername(name))[1] = (public.current_user_couple_id())::text);

drop policy if exists "couple_media_delete" on storage.objects;
create policy "couple_media_delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'couple_media'
     and (storage.foldername(name))[1] = (public.current_user_couple_id())::text);
