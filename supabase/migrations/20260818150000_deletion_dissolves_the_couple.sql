-- Deleting an account is at least leaving the couple — §63's blocker 4.
--
-- delete_my_account with a partner remaining nulled ONLY the deleter's own
-- couple_id. The couple stayed active, the survivor's home screen minted a
-- fresh invite (create_pairing_invite reuses an existing couple), and whoever
-- redeemed it joined the LIVE couple — inheriting the deleted user's entire
-- message history (dual-write-era rows readable in plaintext), gallery and
-- timeline. A stranger, handed an ex's intimate history, by the same RLS that
-- correctly scopes it to "members of the couple".
--
-- The machinery to end a couple properly has existed since 20260601005100 and
-- was hardened in 20260815071024: leave_couple() nulls BOTH profiles'
-- couple_id (so the survivor re-pairs into a NEW couple), consumes every
-- outstanding invite code, and stamps dissolved_at — which starts the 30-day
-- prune_dissolved_couples clock. Deletion simply never called it. Now it
-- does: the else-branch delegates to leave_couple() so the two ways a couple
-- can end cannot drift apart again.
--
-- Consequence, stated because it is a product decision: the survivor loses
-- the shared history 30 days after the partner deletes (prune only fires once
-- no profile points at the couple — which is exactly why the survivor's
-- couple_id must be nulled here). That matches 20260601005100's doctrine
-- ("leaving means leaving") and is what the deletion promise in the privacy
-- policy requires; the old behavior handed that history to a third person
-- instead.
--
-- Second run: no-op (create or replace, same body).
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
--   Re-run the delete_my_account body from
--   20260818090000_db_hygiene_sweep.sql lines 57-122 (the version whose
--   else-path is `update public.profiles set couple_id = null where id =
--   v_uid;` alone). Verified identical to the live prod definition on
--   2026-08-18 before this replace.
-- ───────────────────────────────────────────────────────────────────────────

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

  -- The private vault. OUTSIDE the couple block and outside `v_others = 0`,
  -- because it is this user's alone: a partner staying behind has no claim on
  -- it, and someone who never paired at all still has one to clear.
  begin
    insert into public.storage_reap (bucket_id, name)
    select o.bucket_id, o.name
      from storage.objects o
     where o.bucket_id = 'personal_vault'
       and (storage.foldername(o.name))[1] = v_uid::text
    on conflict do nothing;
  exception when others then
    raise warning 'delete_my_account: personal vault reap-queue failed for %: %',
      v_uid, sqlerrm;
  end;

  delete from auth.users where id = v_uid;
end $fn$;
