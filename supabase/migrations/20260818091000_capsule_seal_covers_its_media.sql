-- Security audit 2026-08-18. The Time Capsule seal was enforced on the ROW and
-- never on the OBJECT.
--
-- capsule_items_select_unlocked requires capsules.unlocked_at is not null, so a
-- sealed capsule's notes are genuinely unreadable. But capsule_media_select
-- tested nothing except the couple folder:
--
--   using (bucket_id='capsule-media'
--          and (storage.foldername(name))[1] = (current_user_couple_id())::text)
--
-- capsule_repository.dart:178 builds the path as
-- '$coupleId/$capsuleId/${type.name}_$rand.$fileExtension', and storage.search
-- is SECURITY INVOKER, so a partner could list the couple folder, read every
-- sealed object's name, and sign a one-hour URL to a photo or voice note weeks
-- before the unlock date. unlocked_at stays null and capsule_items stays
-- empty, so the other partner's phone still shows the capsule as sealed and no
-- trace of the read exists anywhere.
--
-- Second half of the same hole: unlock_date and unlock_mode were still in the
-- authenticated UPDATE column grants, so unlock_capsule()'s own date check
-- could be made to pass by moving the date first. 20260601003200 revoked
-- unlocked_at for exactly this reason and stopped one column short.
--
-- Safe against installed clients, verified before writing:
--   * CapsuleRepository.signedUrl is only ever called with a path taken from
--     items(), which is RLS-gated to unlocked capsules — no legitimate read of
--     a SEALED object exists in the client, so nothing loses access.
--   * The client sets unlock_date/unlock_mode only in create() (an INSERT).
--     There is no reschedule path, so the revoke breaks no shipped flow.
--   * INSERT and DELETE policies are untouched; authors still upload into a
--     sealed capsule and still remove their own contributions.
--
-- Re-runnable: revoke is idempotent, drop-if-exists + create is idempotent.
--
-- Reverse with:
--   grant update (unlock_date, unlock_mode) on public.capsules to authenticated;
--   drop policy if exists "capsule_media_select" on storage.objects;
--   create policy "capsule_media_select" on storage.objects for select to authenticated
--     using (bucket_id = 'capsule-media'
--            and (storage.foldername(name))[1] = (public.current_user_couple_id())::text);

revoke update (unlock_date, unlock_mode) on public.capsules from authenticated, anon;

drop policy if exists "capsule_media_select" on storage.objects;
create policy "capsule_media_select" on storage.objects
  for select to authenticated
  using (
    bucket_id = 'capsule-media'
    and (storage.foldername(name))[1] = (public.current_user_couple_id())::text
    and exists (
      select 1
        from public.capsules c
       where c.couple_id = (public.current_user_couple_id())
         and c.unlocked_at is not null
         and (storage.foldername(name))[2] = c.id::text
    )
  );
