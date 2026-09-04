-- Deleting an account must take the chat background with it.
--
-- A chat background is a photograph the user picks from their own gallery and
-- uploads to the `chat-bg` bucket at `<uid>/bg_<millis>.jpg`
-- (`chat_theme_picker.dart:34-38`). Every other object the app writes is queued
-- for real erasure by `delete_my_account` — couple_media, couple_intimate,
-- capsule-media, couple_files and personal_vault — and `chat-bg` was in none of
-- those lists, so the file outlived the account that owned it, permanently,
-- with no route of any kind to remove it.
--
-- That made three published sentences false at once: the privacy policy's
-- "your account and profile are erased", delete-account.html's "everything else
-- recorded against your account alone", and the Play Data safety answer "users
-- can request that data be deleted". The documents were corrected on
-- 2026-09-04 to concede the gap; this closes it so they can stop conceding.
--
-- The bucket is owner-scoped by uid exactly like personal_vault, so it belongs
-- in the same block: OUTSIDE the couple branch and outside `v_others = 0`,
-- because it is this user's file whether or not they ever paired and whether or
-- not a partner stays behind. One extra bucket id in the existing `in` list is
-- the entire change; nothing else in the function moves.
--
-- Re-runnable: `create or replace` with an identical body is a no-op.
--
-- ROLLBACK — replay this file with the bucket list back to a single value:
--     where o.bucket_id = 'personal_vault'
-- and nothing else changed. No data is destroyed by rolling back; rows already
-- queued in storage_reap stay queued and the hourly drain still honours them.

create or replace function public.delete_my_account()
returns void language plpgsql security definer
set search_path = public
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
      exception when others then
        -- A storage problem must never be the reason an account cannot be
        -- deleted — but it must also never vanish: this warning is the only
        -- record that a couple's media was NOT queued for erasure.
        raise warning 'delete_my_account: couple media reap-queue failed for %: %',
          v_couple, sqlerrm;
      end;

      update public.profiles set couple_id = null where id = v_uid;
      delete from public.messages where couple_id = v_couple;
      delete from public.couples  where id = v_couple;
    else
      -- A partner remains: end the couple the one way the schema knows how.
      -- Nulls both couple_ids, consumes outstanding invites, stamps
      -- dissolved_at. Runs as v_uid — same identity leave_couple derives.
      perform public.leave_couple();
    end if;
  end if;

  -- The user's OWN objects: the private vault, and the chat background.
  -- OUTSIDE the couple block and outside `v_others = 0`, because they are this
  -- user's alone: a partner staying behind has no claim on either, and someone
  -- who never paired at all still has them to clear.
  begin
    insert into public.storage_reap (bucket_id, name)
    select o.bucket_id, o.name
      from storage.objects o
     where o.bucket_id in ('personal_vault', 'chat-bg')
       and (storage.foldername(o.name))[1] = v_uid::text
    on conflict do nothing;
  exception when others then
    raise warning 'delete_my_account: own-object reap-queue failed for %: %',
      v_uid, sqlerrm;
  end;

  delete from auth.users where id = v_uid;
end $function$;
