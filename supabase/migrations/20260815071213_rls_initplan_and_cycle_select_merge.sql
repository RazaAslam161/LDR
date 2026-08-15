-- Two shapes the planner charges per row for.
--
-- A bare auth.uid() in a policy is VOLATILE as far as the planner is
-- concerned, so it is re-executed for every row the query touches instead of
-- once per statement. (select auth.uid()) is an InitPlan: evaluated once. The
-- rest of the schema was converted in 20260810194603; these fourteen are the
-- policies written since, plus the three that arrived with partner_rewrap.
--
-- And the three cycle tables each carried two PERMISSIVE SELECT policies, so
-- every read evaluated both and OR'd the results. Merging them costs the owner
-- policy its ALL shorthand — it becomes an explicit insert/update/delete — for
-- one SELECT policy that says the same thing in one pass. The `user_id <>
-- auth.uid()` guard in the partner branch is dropped: OR'd against
-- `user_id = auth.uid()` it can never change the answer.

drop policy if exists memory_photos_delete_own on public.memory_photos;
create policy memory_photos_delete_own on public.memory_photos
  for delete using (couple_id = (select public.current_user_couple_id())
                    and added_by = (select auth.uid()));
drop policy if exists memory_photos_insert_member on public.memory_photos;
create policy memory_photos_insert_member on public.memory_photos
  for insert with check (added_by = (select auth.uid())
                         and memory_id in (
                           select id from public.memory_threads
                            where couple_id = (select public.current_user_couple_id())));

drop policy if exists notification_mutes_select_own on public.notification_mutes;
create policy notification_mutes_select_own on public.notification_mutes
  for select using (user_id = (select auth.uid()));

drop policy if exists gallery_insert_member on public.gallery_items;
create policy gallery_insert_member on public.gallery_items
  for insert with check (uploaded_by = (select auth.uid())
                         and couple_id = (select public.current_user_couple_id()));

drop policy if exists routine_checks_own_insert on public.routine_checks;
create policy routine_checks_own_insert on public.routine_checks
  for insert with check (user_id = (select auth.uid()));
drop policy if exists routine_checks_own_update on public.routine_checks;
create policy routine_checks_own_update on public.routine_checks
  for update using (user_id = (select auth.uid()))
          with check (user_id = (select auth.uid()));
drop policy if exists routine_checks_own_delete on public.routine_checks;
create policy routine_checks_own_delete on public.routine_checks
  for delete using (user_id = (select auth.uid()));

drop policy if exists shared_reels_insert on public.shared_reels;
create policy shared_reels_insert on public.shared_reels
  for insert with check (couple_id = (select public.current_user_couple_id())
                         and added_by = (select auth.uid()));

drop policy if exists shared_reel_views_own on public.shared_reel_views;
create policy shared_reel_views_own on public.shared_reel_views
  for insert with check (user_id = (select auth.uid()));
drop policy if exists shared_reel_views_own_delete on public.shared_reel_views;
create policy shared_reel_views_own_delete on public.shared_reel_views
  for delete using (user_id = (select auth.uid()));

drop policy if exists watch_sessions_write on public.watch_sessions;
create policy watch_sessions_write on public.watch_sessions
  for insert with check (couple_id = (select public.current_user_couple_id())
                         and started_by = (select auth.uid()));

drop policy if exists partner_rewrap_open on public.partner_rewrap_requests;
create policy partner_rewrap_open on public.partner_rewrap_requests
  for insert with check (couple_id = (select public.current_user_couple_id())
                         and from_user = (select auth.uid()));
drop policy if exists partner_rewrap_answer on public.partner_rewrap_requests;
create policy partner_rewrap_answer on public.partner_rewrap_requests
  for update using (couple_id = (select public.current_user_couple_id())
                    and from_user <> (select auth.uid())
                    and wrapped_keys is null
                    and expires_at > now())
          with check (couple_id = (select public.current_user_couple_id())
                      and from_user <> (select auth.uid())
                      and wrapped_by = (select auth.uid()));
drop policy if exists partner_rewrap_close on public.partner_rewrap_requests;
create policy partner_rewrap_close on public.partner_rewrap_requests
  for delete using (from_user = (select auth.uid()));

-- ── cycle_*: one SELECT policy each ────────────────────────────────────────
-- Two owner names for events and settings: prod carries _owner, the migration
-- that creates the tables (20260601002220) writes _own, and the rename between
-- them was never committed. Dropping both is what makes a rebuild from this
-- directory land on the policy set prod actually has. cycle_logs only ever had
-- _owner.
drop policy if exists cycle_events_own on public.cycle_events;
drop policy if exists cycle_events_owner on public.cycle_events;
drop policy if exists cycle_events_partner_read on public.cycle_events;
create policy cycle_events_read on public.cycle_events
  for select using (
    user_id = (select auth.uid())
    or (couple_id = (select public.current_user_couple_id())
        and exists (select 1 from public.cycle_settings s
                     where s.user_id = cycle_events.user_id and s.share_with_partner)));
create policy cycle_events_insert on public.cycle_events
  for insert with check (user_id = (select auth.uid()));
create policy cycle_events_update on public.cycle_events
  for update using (user_id = (select auth.uid()))
          with check (user_id = (select auth.uid()));
create policy cycle_events_delete on public.cycle_events
  for delete using (user_id = (select auth.uid()));

drop policy if exists cycle_logs_owner on public.cycle_logs;
drop policy if exists cycle_logs_partner_read on public.cycle_logs;
create policy cycle_logs_read on public.cycle_logs
  for select using (
    user_id = (select auth.uid())
    or (couple_id = (select public.current_user_couple_id())
        and exists (select 1 from public.cycle_settings s
                     where s.user_id = cycle_logs.user_id and s.share_with_partner)));
create policy cycle_logs_insert on public.cycle_logs
  for insert with check (user_id = (select auth.uid()));
create policy cycle_logs_update on public.cycle_logs
  for update using (user_id = (select auth.uid()))
          with check (user_id = (select auth.uid()));
create policy cycle_logs_delete on public.cycle_logs
  for delete using (user_id = (select auth.uid()));

drop policy if exists cycle_settings_own on public.cycle_settings;
drop policy if exists cycle_settings_owner on public.cycle_settings;
drop policy if exists cycle_settings_partner_read on public.cycle_settings;
create policy cycle_settings_read on public.cycle_settings
  for select using (user_id = (select auth.uid())
                    or couple_id = (select public.current_user_couple_id()));
create policy cycle_settings_insert on public.cycle_settings
  for insert with check (user_id = (select auth.uid()));
create policy cycle_settings_update on public.cycle_settings
  for update using (user_id = (select auth.uid()))
          with check (user_id = (select auth.uid()));
create policy cycle_settings_delete on public.cycle_settings
  for delete using (user_id = (select auth.uid()));
