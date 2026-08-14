-- `delete from storage.objects` does not delete a file. It destroys the only
-- pointer to one.
--
-- Verified on this project: storage.objects carries a `version` column, and
-- Supabase stores the physical object at <bucket>/<name>/<version>. That
-- version string lives nowhere else. Delete the row and the bytes remain in the
-- backing store — unreachable through the API, never garbage collected, still
-- billed, and now impossible to erase because nothing knows where they are.
--
-- Two callers were doing exactly that, both believing the opposite:
--
--   reap_storage_objects()  — 007000's drain of the memory-photo reap queue.
--                             §5's copy promises "the encrypted files are
--                             erased within 30 days".
--
--   delete_my_account()     — 003400, which erases a couple's whole media
--                             library when the last member leaves. So "delete
--                             my account" left every photograph, video and
--                             voice note that couple ever sent on the server,
--                             permanently. That is the one in this file that
--                             matters most.
--
-- The Storage API deletes the row AND the object, so the drain has to go
-- through it, which needs the service role, which means the `reap-storage`
-- edge function. Postgres' job is now only to QUEUE, and to poke the function.

-- ── The drain is a poke, not a delete ──────────────────────────────────────
create or replace function public.reap_storage_objects()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_url text := public.functions_base_url();
begin
  if v_url is null then
    raise warning 'reap_storage_objects: FUNCTIONS_BASE_URL unset - queue not drained';
    return;
  end if;
  -- Nothing to do is the common case; do not spend a request on it.
  if not exists (select 1 from public.storage_reap) then return; end if;
  perform net.http_post(
    url := v_url || '/functions/v1/reap-storage',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-notify-secret', coalesce(public.notify_secret(), ''))
  );
end $fn$;
revoke execute on function public.reap_storage_objects() from public, anon, authenticated;

-- ── Account deletion queues instead of orphaning ───────────────────────────
-- Structure preserved exactly; only the two `delete from storage.objects`
-- statements become inserts into the queue. The exception block stays: a
-- storage problem must never be the reason an account cannot be deleted.
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public as $fn$
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

    if v_others = 0 then
      begin
        insert into public.storage_reap (bucket_id, name)
        select o.bucket_id, o.name
          from storage.objects o
          join public.messages m on m.couple_id = v_couple
         where (o.bucket_id = 'couple_media'
                  and o.name in (m.image_path, m.voice_path))
            or (o.bucket_id = 'couple_intimate' and o.name = m.video_path)
            or (o.bucket_id = 'couple_files'    and o.name = m.file_path)
        on conflict do nothing;

        insert into public.storage_reap (bucket_id, name)
        select o.bucket_id, o.name
          from storage.objects o
         where o.bucket_id in ('couple_media', 'couple_intimate',
                               'capsule-media', 'couple_files')
           and (storage.foldername(o.name))[1] = v_couple::text
        on conflict do nothing;
      exception when others then null;
      end;
    end if;

    update public.profiles set couple_id = null where id = v_uid;
    if v_others = 0 then
      delete from public.messages where couple_id = v_couple;
      delete from public.couples  where id = v_couple;
    end if;
  end if;

  delete from auth.users where id = v_uid;
end $fn$;

-- ── Drain more often than once a night ─────────────────────────────────────
-- A deletion the user was told is happening should not sit visible in a bucket
-- for up to 24 hours. The purge of soft-deleted memories stays nightly; the
-- drain is cheap (one HTTP post, and it returns immediately when the queue is
-- empty) so it runs hourly.
do $do$ begin
  if exists (select 1 from pg_extension where extname='pg_cron') then
    if exists (select 1 from cron.job where jobname='purge-deleted-memories')
      then perform cron.unschedule('purge-deleted-memories'); end if;
    perform cron.schedule('purge-deleted-memories','17 3 * * *',
      $j$select public.purge_deleted_memories();$j$);

    if exists (select 1 from cron.job where jobname='drain-storage-reap')
      then perform cron.unschedule('drain-storage-reap'); end if;
    perform cron.schedule('drain-storage-reap','23 * * * *',
      $j$select public.reap_storage_objects();$j$);
  end if;
end $do$;
