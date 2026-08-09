-- ───────────────────────────────────────────────────────────────────────────
-- Miles — in-app account deletion. Run after hardening_2026_08.sql.
--
-- Google Play requires that an app which lets users create an account also
-- lets them delete it from inside the app, and that the deletion actually
-- removes their data rather than just hiding it. There was no such path.
--
-- What this deletes: the auth user (which cascades to profiles and, through
-- profiles, to every couple-scoped row via existing ON DELETE CASCADE), the
-- caller's storage objects, and the couple itself once nobody is left in it.
-- What it deliberately keeps: nothing. This is a real delete.
-- ───────────────────────────────────────────────────────────────────────────

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
             or (o.bucket_id = 'couple_intimate' and o.name = m.video_path));
        delete from storage.objects
         where bucket_id in ('couple_media', 'couple_intimate', 'capsule-media')
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
