-- ───────────────────────────────────────────────────────────────────────────
-- Miles — leaving now means now.
--
-- WHY THIS LANDS BEFORE THE RESTORE PATH, NOT AFTER. 20260826160000 made a
-- dissolved couple addressable, and 20260826190000 will make it restorable.
-- Between those two there must never be a deployed state in which restoration
-- exists and the way to refuse it does not. THREAT-MODEL.md §3 sells unpair as
-- the exit from a partner who has become dangerous; a 30-day window that only
-- one person can close is not an exit, it is a door left ajar.
--
-- THE COALESCE IS THE REQUIREMENT, NOT AN OPTIMISATION. A unpairs normally.
-- That opens a 30-day window over BOTH people's history — and B never chose
-- it. B is already unpaired, so B has no `profiles.couple_id` to resolve, and
-- an implementation that only looked there would hand the escape exclusively
-- to whoever moved first. That is precisely backwards. So the couple is
-- resolved as:
--     coalesce(my current couple, current_user_restorable_couple_id())
-- and either ex-member can end it at any point inside the window.
--
-- SEVERING BINDS THE COUPLE, NOT THE PERSON. `severed_at` is stamped on EVERY
-- row of the couple, never just the caller's. Stamp only your own and the
-- other person's `current_user_restorable_couple_id()` still resolves, so they
-- could restore unilaterally — which is the entire attack this function
-- exists to prevent.
--
-- IT NEVER CONFIRMS OR DENIES. With nothing to purge it returns silently
-- rather than raising: an error message is an oracle, and "no couple to end"
-- told to the wrong person at the wrong moment is information about somebody
-- who left. Same reasoning as couple_restore_state()'s uniform null.
--
-- NOTHING IS ANNOUNCED. No push, no realtime row, no readable state. The
-- couple_members rows carrying `severed_at` are own-rows-only and are deleted
-- by the purge in the same transaction anyway.
--
-- ON THE BELT AND BRACES, HONESTLY. The `severed_at` stamp and the backdated
-- `dissolved_at` are redundant TODAY: this is one plpgsql function, so it is
-- one transaction, and if the purge raises then the stamp and the backdate
-- roll back with it. They are here because they cost nothing and they are what
-- makes the outcome still correct if a later change ever defers the purge to
-- the cron instead of running it inline. Stated rather than implied, so nobody
-- reads them as a guarantee they are not.
-- ───────────────────────────────────────────────────────────────────────────

-- ── One purge, two callers ─────────────────────────────────────────────────
-- Internal only. The uuid parameter makes no identity decision — every caller
-- has already authorised against auth.uid() before getting here — which is why
-- execute is revoked from every client role rather than merely from anon.
create or replace function public.purge_couple(p_couple uuid)
returns void language plpgsql security definer set search_path = public as $fn$
declare v_members uuid[];
begin
  if p_couple is null then return; end if;

  select coalesce(array_agg(user_id), '{}') into v_members
    from public.couple_members where couple_id = p_couple;

  -- Storage first, while the couple still exists to name it. The folder-prefix
  -- sweep is complete for these four buckets because every object in them is
  -- stored under `<couple_id>/…` — that is what the storage RLS policies
  -- resolve against — so it catches thumbnails too, which live at
  -- `<couple_id>/thumb/<file>` and share the prefix. personal_vault is
  -- deliberately absent: it is owner-scoped, sealed under a key derived from
  -- the owner's own seed, and survives a breakup untouched.
  --
  -- QUEUED, NEVER DELETED. `delete from storage.objects` destroys the version
  -- column that is the only pointer to the bytes at <bucket>/<name>/<version>,
  -- leaving them billed, unreachable and un-erasable forever.
  insert into public.storage_reap (bucket_id, name)
  select o.bucket_id, o.name
    from storage.objects o
   where o.bucket_id in ('couple_media','couple_intimate','capsule-media',
                         'couple_files')
     and (storage.foldername(o.name))[1] = p_couple::text
  on conflict do nothing;

  -- Presence rows are the one thing the cascade cannot reach: leave_couple()
  -- has already nulled presence.couple_id, so the FK no longer points at the
  -- couple being deleted and the row would survive as an orphan.
  --
  -- The coalesce guard is load-bearing. A member may have paired with somebody
  -- NEW since; their presence row now belongs to that relationship and must
  -- not be touched. Only a row that is unattached, or still attached to the
  -- couple being purged, is in scope.
  if array_length(v_members, 1) is not null then
    update public.presence
       set is_online = false, is_typing = false, typing_in_chat = false,
           app_last_active_at = null, current_screen = null,
           current_activity = null, current_mood = null, mood_color = null,
           mood_updated_at = null, latitude = null, longitude = null,
           location_accuracy = null, location_label = null,
           location_sharing_mode = 'off', location_updated_at = null,
           body_photo_path = null, avatar_emoji = null,
           checkin_photo_url = null, checkin_photo_at = null,
           chat_last_read = null, couple_id = null, updated_at = now()
     where user_id = any (v_members)
       and coalesce(couple_id, p_couple) = p_couple;
  end if;

  -- And the couple. Every couple-scoped table cascades from here — the same
  -- foreign keys account deletion depends on, couple_members among them — so
  -- this needs no table list that would rot the next time a feature adds one.
  delete from public.couples where id = p_couple;
end $fn$;

revoke execute on function public.purge_couple(uuid) from public, anon, authenticated;

-- ── The reaper now shares that implementation ──────────────────────────────
-- Same selection as the live production body (captured with pg_get_functiondef
-- and diffed before writing this); only the storage queue and the delete move
-- into purge_couple, so the scheduled path and the immediate path can never
-- drift apart about what "purged" means.
create or replace function public.prune_dissolved_couples()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_id uuid;
begin
  for v_id in
    select id from public.couples
     where dissolved_at is not null
       and dissolved_at < now() - public.dissolution_window()
       and not exists (select 1 from public.profiles p where p.couple_id = couples.id)
  loop
    perform public.purge_couple(v_id);
  end loop;
end $fn$;

revoke execute on function public.prune_dissolved_couples() from public, anon, authenticated;

-- ── The escape ─────────────────────────────────────────────────────────────
create or replace function public.leave_couple_permanently()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_uid uuid := auth.uid(); v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  -- See the header: the second arm is what lets the person who did NOT
  -- initiate close a window opened over their own history.
  v_couple := coalesce(
    (select couple_id from public.profiles where id = v_uid),
    public.current_user_restorable_couple_id()
  );

  -- Silent. Never confirm or deny.
  if v_couple is null then return; end if;

  -- Still paired: dissolve first, through the one implementation rather than a
  -- second copy of it. 20260818150000 set this precedent for delete_my_account
  -- and gave the reason — so the ways a couple can end cannot drift apart.
  if exists (select 1 from public.profiles
              where id = v_uid and couple_id = v_couple) then
    perform public.leave_couple();
  end if;

  -- Every row, both people. See the header.
  update public.couple_members
     set severed_at = now()
   where couple_id = v_couple and severed_at is null;

  update public.couples
     set dissolved_at = now() - public.dissolution_window() - interval '1 day'
   where id = v_couple;

  -- Inline, so "now" means now rather than "within 24 hours".
  perform public.purge_couple(v_couple);
end $fn$;

revoke execute on function public.leave_couple_permanently() from public, anon;
grant  execute on function public.leave_couple_permanently() to authenticated;

-- ── Assertion: the escape cannot be gated by anyone's consent ──────────────
-- The property that must never regress. If a future edit makes this function
-- depend on couple_restore_requests, or on the other member's agreement, the
-- safety exit becomes something the other person can hold open.
do $do$
declare v_src text;
begin
  select pg_get_functiondef(p.oid) into v_src
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname='public' and p.proname='leave_couple_permanently';
  if position('current_user_restorable_couple_id' in v_src) = 0 then
    raise exception
      'leave_couple_permanently no longer resolves the restorable couple — the '
      'person who did not initiate the unpair can no longer close the window '
      'over their own history';
  end if;
  if position('couple_restore_requests' in v_src) > 0
  or position('confirmed_by' in v_src) > 0 then
    raise exception
      'leave_couple_permanently references the consent handshake — the safety '
      'exit must never be gated on the other person agreeing to it';
  end if;
end $do$;

-- ── Assertion: purge_couple is unreachable by any client ───────────────────
do $do$
begin
  if has_function_privilege('authenticated', 'public.purge_couple(uuid)', 'EXECUTE')
  or has_function_privilege('anon', 'public.purge_couple(uuid)', 'EXECUTE')
  then
    raise exception
      'purge_couple is callable by a client role — it takes a couple id and '
      'makes no identity decision, so it must only ever be reached through a '
      'caller that has already authorised against auth.uid()';
  end if;
end $do$;

-- ── ROLLBACK ───────────────────────────────────────────────────────────────
--   drop function if exists public.leave_couple_permanently();
--   create or replace function public.prune_dissolved_couples() ...
--     -- the array form from 20260826160000, which inlines the storage sweep
--     -- and the delete instead of calling purge_couple
--   drop function if exists public.purge_couple(uuid);
-- Drop order matters: prune must stop calling purge_couple before it is
-- dropped.
--
-- ROLLBACK DOES NOT UN-PURGE. Anything this function deleted is gone, and any
-- storage object it queued will be erased by the next drain-storage-reap run
-- whether or not the function still exists. That is the contract, not a
-- shortcoming: a permanent exit that could be reversed by a migration would
-- not be one.
--
-- Second run: no-op. All three are create-or-replace; the assertions are
-- read-only.
