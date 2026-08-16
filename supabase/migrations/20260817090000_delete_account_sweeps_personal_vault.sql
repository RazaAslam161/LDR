-- delete_my_account did not sweep the personal_vault bucket.
--
-- personal_vault_items.owner_id cascades from profiles, so the ROWS went when
-- the account did. The encrypted BLOBS did not: nothing queued them, nothing
-- referenced them afterwards, and they sat in storage forever under the uuid of
-- a user who no longer existed. A deleted account left its vault behind.
--
-- That is a data-deletion claim the app makes to its users and will make to
-- Google on the Data safety form, so it has to be true rather than nearly true.
--
-- Owner-scoped, NOT couple-scoped, and that difference is the whole reason it
-- was missed: every other bucket here is shared between partners and can only
-- be swept when the LAST member leaves, so the existing sweep sits inside
-- `if v_others = 0`. The private vault belongs to one person. It goes when that
-- person goes, whether or not a partner remains.
--
-- Paths are `<owner_id>/vault/<id>.enc` and `<owner_id>/vault/thumb/<id>.enc`
-- (VaultRepository._fullPath / _thumbPath), so folder[1] is the owner uuid.
--
-- Re-running this migration is a no-op: it is a single create-or-replace of a
-- function body, with no DDL and no data change.
--
-- ROLLBACK — restores the definition that is live at the time of writing,
-- captured from pg_get_functiondef rather than from a migration file, because
-- the live body had already moved to the storage_reap queue and the file on
-- disk was stale:
--
--   create or replace function public.delete_my_account()
--   returns void language plpgsql security definer set search_path to 'public'
--   as $rollback$
--   declare
--     v_uid    uuid := auth.uid();
--     v_couple uuid;
--     v_others int;
--   begin
--     if v_uid is null then raise exception 'not_authenticated'; end if;
--     select couple_id into v_couple from public.profiles where id = v_uid;
--     if v_couple is not null then
--       select count(*) into v_others
--         from public.profiles where couple_id = v_couple and id <> v_uid;
--       if v_others = 0 then
--         begin
--           insert into public.storage_reap (bucket_id, name)
--           select o.bucket_id, o.name
--             from storage.objects o
--             join public.messages m on m.couple_id = v_couple
--            where (o.bucket_id = 'couple_media'
--                     and o.name in (m.image_path, m.voice_path))
--               or (o.bucket_id = 'couple_intimate' and o.name = m.video_path)
--               or (o.bucket_id = 'couple_files'    and o.name = m.file_path)
--           on conflict do nothing;
--           insert into public.storage_reap (bucket_id, name)
--           select o.bucket_id, o.name
--             from storage.objects o
--            where o.bucket_id in ('couple_media', 'couple_intimate',
--                                  'capsule-media', 'couple_files')
--              and (storage.foldername(o.name))[1] = v_couple::text
--           on conflict do nothing;
--         exception when others then null;
--         end;
--       end if;
--       update public.profiles set couple_id = null where id = v_uid;
--       if v_others = 0 then
--         delete from public.messages where couple_id = v_couple;
--         delete from public.couples  where id = v_couple;
--       end if;
--     end if;
--     delete from auth.users where id = v_uid;
--   end $rollback$;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
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

  -- The private vault. OUTSIDE the couple block and outside `v_others = 0`,
  -- because it is this user's alone: a partner staying behind has no claim on
  -- it, and someone who never paired at all still has one to clear.
  --
  -- Same best-effort posture as the sweep above — a storage hiccup must not
  -- strand a user with an account they asked to delete and cannot delete. The
  -- rows go regardless via the owner_id cascade; this only queues the blobs.
  begin
    insert into public.storage_reap (bucket_id, name)
    select o.bucket_id, o.name
      from storage.objects o
     where o.bucket_id = 'personal_vault'
       and (storage.foldername(o.name))[1] = v_uid::text
    on conflict do nothing;
  exception when others then null;
  end;

  delete from auth.users where id = v_uid;
end $function$;
