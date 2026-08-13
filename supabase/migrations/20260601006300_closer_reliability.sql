-- Close the schema gaps between the Closer client and production. These
-- columns are intentionally additive so existing encrypted rows remain valid.

alter table public.rituals
  add column if not exists delete_requested boolean not null default false,
  add column if not exists delete_requested_by uuid references public.profiles(id) on delete set null,
  add column if not exists delete_requested_at timestamptz,
  add column if not exists deleted boolean not null default false,
  add column if not exists deleted_by uuid references public.profiles(id) on delete set null,
  add column if not exists deleted_at timestamptz;

create index if not exists rituals_active_delivery_idx
  on public.rituals(couple_id, deliver_at)
  where deleted = false;

alter table public.afterglow_entries
  add column if not exists delete_requested boolean not null default false,
  add column if not exists delete_requested_by uuid references public.profiles(id) on delete set null,
  add column if not exists delete_requested_at timestamptz,
  add column if not exists deleted boolean not null default false,
  add column if not exists deleted_by uuid references public.profiles(id) on delete set null,
  add column if not exists deleted_at timestamptz;

create index if not exists afterglow_active_timeline_idx
  on public.afterglow_entries(couple_id, happened_at desc)
  where deleted = false;

alter table public.memory_threads
  add column if not exists delete_requested_by uuid references public.profiles(id) on delete set null,
  add column if not exists delete_requested_at timestamptz,
  add column if not exists deleted_by uuid references public.profiles(id) on delete set null,
  add column if not exists deleted_at timestamptz;

-- Vault media is encrypted before upload, so its wire format is deliberately
-- opaque. Keep the original MIME type and immutable storage path as encrypted
-- metadata, while permitting the encrypted object type in the private bucket.
alter table public.vault_items
  add column if not exists storage_path text,
  add column if not exists media_mime_type text;

-- Encrypted vault originals live below the couple UUID. Existing chat-video
-- objects use the same namespace, so these policies make both flows explicit
-- and keep one couple from reading or writing another couple's media.
insert into storage.buckets (id, name, public, file_size_limit)
values ('couple_intimate', 'couple_intimate', false, 104857600)
on conflict (id) do update
  set public = false,
      file_size_limit = 104857600;

update storage.buckets
   set allowed_mime_types = (
     select array_agg(distinct mime order by mime)
       from unnest(
         coalesce(allowed_mime_types, array[]::text[]) ||
         array['application/octet-stream']::text[]
       ) as allowed_mime(mime)
   )
 where id = 'couple_intimate';

drop policy if exists closer_intimate_media_read on storage.objects;
create policy closer_intimate_media_read on storage.objects
  for select to authenticated
  using (
    bucket_id = 'couple_intimate'
    and (storage.foldername(name))[1] = (select public.current_user_couple_id())::text
  );

drop policy if exists closer_intimate_media_upload on storage.objects;
create policy closer_intimate_media_upload on storage.objects
  for insert to authenticated
  with check (
    bucket_id = 'couple_intimate'
    and (storage.foldername(name))[1] = (select public.current_user_couple_id())::text
  );

drop policy if exists closer_intimate_media_delete on storage.objects;
create policy closer_intimate_media_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id = 'couple_intimate'
    and (storage.foldername(name))[1] = (select public.current_user_couple_id())::text
  );
