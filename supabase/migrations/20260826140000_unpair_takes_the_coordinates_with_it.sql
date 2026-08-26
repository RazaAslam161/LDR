-- ───────────────────────────────────────────────────────────────────────────
-- Miles — unpair takes the coordinates with it.
--
-- THE BUG, AND IT IS LIVE. leave_couple() has not cleared a single sensitive
-- presence field since 2026-06. 20260601002400_leave_couple_privacy.sql added
-- an explicit 16-column wipe, with a long ORDERING NOTE explaining why it must
-- run first. 20260601005100_dissolved_couple_retention.sql then
-- `create or replace`d leave_couple() with a short body to add dissolved_at —
-- and dropped the wipe entirely. 20260815071024_invites_die_with_the_couple.sql
-- inherited the shortened body. Nothing failed, no test noticed, and the
-- function has been shipping without it ever since.
--
-- The only cleanup left standing is trg_sync_presence_couple_id ->
-- sync_presence_couple_id() (20260601002600), which nulls four columns:
-- couple_id, is_online, app_last_active_at, current_screen. Everything else
-- survives.
--
-- WHY THAT IS WORSE THAN IT LOOKS. The surviving row has couple_id = NULL, so
-- prune_dissolved_couples() can never reach it — its FK cascade fires on the
-- couples row, and this row no longer points at one. It is not merely stale, it
-- is unreachable by every cleanup path in the schema. And it does not stay
-- quiet: sync_presence_couple_id() UPSERTs couple_id = NEW.couple_id on the
-- next pairing (20260601002600:39-45), which re-attaches the row, at which
-- point the NEW partner's presence_select_couple policy (20260601000300:32-34)
-- reads every field on it. That is precisely the leak 20260601002400 was
-- written to close.
--
-- MEASURED ON PRODUCTION BEFORE WRITING THIS, not inferred:
--   total_rows 3, orphaned 3, with coords 2, with location_label 2,
--   with checkin photo 2, with mood 2, and location_sharing_mode <> 'off' 2.
-- The last one is the sharpest: two rows say live location sharing is ON. Pair
-- either of those accounts with someone new and the new partner gets a pin and
-- a sharing mode nobody turned on. Both check-in paths were confirmed to be
-- paths (not legacy URLs) in bucket couple_media, and both objects still exist.
--
-- Live prod's leave_couple() body was captured with pg_get_functiondef and
-- diffed against 20260815071024 before this file was written: byte-identical,
-- no drift. The replacement below is that body plus the scrub.
--
-- THE ORDERING NOTE FROM 20260601002400 STILL BINDS. The scrub must run BEFORE
-- the profiles UPDATE. That UPDATE fires trg_sync_presence_couple_id, which
-- nulls presence.couple_id immediately, so a scrub placed after it would match
-- zero rows and silently do nothing — which looks exactly like a scrub that
-- worked.
--
-- STORAGE IS QUEUED, NEVER DELETED HERE. A `delete from storage.objects`
-- destroys the version column that is the only pointer to the bytes at
-- <bucket>/<name>/<version>, leaving them billed, unreachable and un-erasable
-- forever (20260601007500, reap-storage/index.ts:1-24). Queue into
-- storage_reap and let the hourly drain do it, exactly as clear_body_photo()
-- does for this same column.
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.leave_couple()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_uid uuid := auth.uid(); v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then return; end if;

  -- 1) The photographs, queued while the paths are still readable. Selected
  --    FROM storage.objects rather than inserted blind, so a path that no
  --    longer resolves — or a legacy row still holding a full URL from before
  --    checkin_photo_url stored a path — queues nothing instead of queueing a
  --    name the reaper will never find.
  insert into public.storage_reap (bucket_id, name)
  select o.bucket_id, o.name
    from public.presence p
    join storage.objects o
      on (o.bucket_id = 'couple_intimate' and o.name = p.body_photo_path)
      or (o.bucket_id = 'couple_media'    and o.name = p.checkin_photo_url)
   where p.couple_id = v_couple
  on conflict do nothing;

  -- 2) Both partners' rows, BEFORE the profiles update (see ORDERING NOTE).
  --    location_sharing_mode is set rather than nulled because it is NOT NULL,
  --    and 'off' is the only value that does not re-arm sharing on re-pair.
  --    last_seen and user_id are deliberately left alone: they describe the
  --    account that owns the row, not the relationship that ended.
  update public.presence
     set couple_id             = null,
         is_online             = false,
         is_typing             = false,
         typing_in_chat        = false,
         app_last_active_at    = null,
         current_screen        = null,
         current_activity      = null,
         current_mood          = null,
         mood_color            = null,
         mood_updated_at       = null,
         latitude              = null,
         longitude             = null,
         location_accuracy     = null,
         location_label        = null,
         location_sharing_mode = 'off',
         location_updated_at   = null,
         body_photo_path       = null,
         avatar_emoji          = null,
         checkin_photo_url     = null,
         checkin_photo_at      = null,
         chat_last_read        = null,
         updated_at            = now()
   where couple_id = v_couple;

  -- 3) Everything 20260815071024 did, unchanged.
  update public.profiles set couple_id = null where couple_id = v_couple;
  -- consumed_by stays null: nobody redeemed these, the couple ended under them.
  update public.pairing_invites set consumed_at = now()
   where couple_id = v_couple and consumed_at is null;
  update public.couples
     set active = false,
         -- Starts the 30-day clock. NOTE: the comment this replaces claimed
         -- "Re-pairing clears it, so a reconciliation inside the window keeps
         -- everything." That is false and has been since 20260601005900 —
         -- create_pairing_invite mints a NEW couple for a caller with none, and
         -- redeem_pairing_invite raises couple_dissolved for any invite
         -- pointing at a dissolved one (20260815071024:73-77). There is no path
         -- back to this couple_id today. Restoring one is a later migration;
         -- the false promise is removed here so nobody else builds on it.
         dissolved_at = coalesce(dissolved_at, now())
   where id = v_couple;
end $fn$;

revoke execute on function public.leave_couple() from public, anon;
grant  execute on function public.leave_couple() to authenticated;

-- ── The rows the broken function already left behind ───────────────────────
-- Fixing the function does nothing for couples that have already dissolved.
-- Those rows are the live exposure, and they are the ones waiting to re-attach
-- on the next pairing. Reports counts rather than running silently: 0 touched
-- on a table that should have data is a failure, not a success.
do $do$
declare v_reaped int; v_scrubbed int;
begin
  insert into public.storage_reap (bucket_id, name)
  select o.bucket_id, o.name
    from public.presence p
    join storage.objects o
      on (o.bucket_id = 'couple_intimate' and o.name = p.body_photo_path)
      or (o.bucket_id = 'couple_media'    and o.name = p.checkin_photo_url)
   where p.couple_id is null
  on conflict do nothing;
  get diagnostics v_reaped = row_count;

  update public.presence
     set is_online             = false,
         is_typing             = false,
         typing_in_chat        = false,
         app_last_active_at    = null,
         current_screen        = null,
         current_activity      = null,
         current_mood          = null,
         mood_color            = null,
         mood_updated_at       = null,
         latitude              = null,
         longitude             = null,
         location_accuracy     = null,
         location_label        = null,
         location_sharing_mode = 'off',
         location_updated_at   = null,
         body_photo_path       = null,
         avatar_emoji          = null,
         checkin_photo_url     = null,
         checkin_photo_at      = null,
         chat_last_read        = null,
         updated_at            = now()
   where couple_id is null
     and (latitude is not null or longitude is not null
          or location_label is not null or location_updated_at is not null
          or location_accuracy is not null or location_sharing_mode <> 'off'
          or current_mood is not null or mood_color is not null
          or mood_updated_at is not null or current_activity is not null
          or current_screen is not null or body_photo_path is not null
          or avatar_emoji is not null or checkin_photo_url is not null
          or checkin_photo_at is not null or chat_last_read is not null
          or app_last_active_at is not null
          or is_online or is_typing or typing_in_chat);
  get diagnostics v_scrubbed = row_count;

  raise notice 'orphaned presence rows scrubbed: %, storage objects queued: %',
    v_scrubbed, v_reaped;
end $do$;

-- ── The guard that would have caught this in 2026-06 ───────────────────────
-- A regression this quiet is a process failure, not a typing one: the wipe was
-- a list of column names in a function body, and nothing anywhere tied that
-- list to the table it was clearing. So the next ALTER TABLE presence ADD
-- COLUMN now fails the migration that writes it, until somebody decides
-- whether the new field is couple PII or not, in the same commit that adds it.
do $do$
declare v_unknown text;
begin
  select string_agg(column_name, ', ' order by column_name) into v_unknown
    from information_schema.columns
   where table_schema = 'public' and table_name = 'presence'
     and column_name not in (
       -- cleared by leave_couple() above
       'couple_id','is_online','is_typing','typing_in_chat','app_last_active_at',
       'current_screen','current_activity','current_mood','mood_color',
       'mood_updated_at','latitude','longitude','location_accuracy',
       'location_label','location_sharing_mode','location_updated_at',
       'body_photo_path','avatar_emoji','checkin_photo_url','checkin_photo_at',
       'chat_last_read','updated_at',
       -- deliberately kept: they describe the account, not the relationship
       'user_id','last_seen'
     );
  if v_unknown is not null then
    raise exception
      'presence gained column(s) % — decide keep-or-clear in leave_couple() '
      'and add it to this list, in this migration''s successor', v_unknown;
  end if;
end $do$;

-- ── ROLLBACK ───────────────────────────────────────────────────────────────
-- Restore the previous function body verbatim from
--   20260815071024_invites_die_with_the_couple.sql lines 19-36
-- (captured from production with pg_get_functiondef before this file was
-- applied; byte-identical to that file). Then re-run its grant pair:
--   revoke execute on function public.leave_couple() from public, anon;
--   grant  execute on function public.leave_couple() to authenticated;
-- The two do-blocks leave no object behind, so nothing else needs dropping.
--
-- Rollback does NOT un-scrub. The presence fields cleared by the backfill are
-- gone, and any storage object it queued will be erased by the next
-- drain-storage-reap run. That is the contract: this migration exists to
-- destroy that data.
--
-- Second run: no-op. create or replace is idempotent; the storage_reap inserts
-- are `on conflict do nothing`; the backfill UPDATE's WHERE clause matches
-- nothing once the rows are clean; the assertion is read-only.
