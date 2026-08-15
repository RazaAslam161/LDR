-- delete_my_account has to survive its own cascade.
--
-- It ends in `delete from auth.users`, which cascades to profiles, and drops
-- public.couples when the last member goes. Every foreign key pointing at
-- either of those two rows is then enforced by a query the child table has no
-- index for, so Postgres seq-scans the whole child — once per constraint, per
-- deleted row, inside the 8s statement_timeout. Today the tables are empty
-- enough that it returns; gallery_items, routine_checks and shared_reel_views
-- are the ones that grow per couple per day, and the first one to get large
-- turns account deletion into 57014 for everybody. Deleting your account is a
-- GDPR and a Play requirement, not a feature that may degrade.
--
-- These are exactly the constraints the performance advisor lists as
-- unindexed_foreign_keys. All 20 are on the cascade path: 17 reference
-- profiles, partner_rewrap_requests.couple_id references couples, and
-- memory_threads.cover_photo_id / .visit_id reference memory_photos and
-- visits, both of which are themselves cascade-deleted with the couple.
--
-- Plain CREATE INDEX, not CONCURRENTLY: a migration runs in one transaction,
-- and at this size the exclusive lock is milliseconds.

create index if not exists afterglow_entries_delete_requested_by_idx
  on public.afterglow_entries (delete_requested_by);
create index if not exists afterglow_entries_deleted_by_idx
  on public.afterglow_entries (deleted_by);

create index if not exists gallery_items_delete_requested_by_idx
  on public.gallery_items (delete_requested_by);
create index if not exists gallery_items_deleted_by_idx
  on public.gallery_items (deleted_by);
create index if not exists gallery_items_uploaded_by_idx
  on public.gallery_items (uploaded_by);

create index if not exists memory_photos_added_by_idx
  on public.memory_photos (added_by);

create index if not exists memory_threads_cover_photo_id_idx
  on public.memory_threads (cover_photo_id);
create index if not exists memory_threads_delete_requested_by_idx
  on public.memory_threads (delete_requested_by);
create index if not exists memory_threads_deleted_by_idx
  on public.memory_threads (deleted_by);
create index if not exists memory_threads_visit_id_idx
  on public.memory_threads (visit_id);

create index if not exists notification_mutes_partner_id_idx
  on public.notification_mutes (partner_id);

create index if not exists partner_rewrap_requests_couple_id_idx
  on public.partner_rewrap_requests (couple_id);
create index if not exists partner_rewrap_requests_wrapped_by_idx
  on public.partner_rewrap_requests (wrapped_by);

create index if not exists rituals_delete_requested_by_idx
  on public.rituals (delete_requested_by);
create index if not exists rituals_deleted_by_idx
  on public.rituals (deleted_by);

create index if not exists routine_checks_user_id_idx
  on public.routine_checks (user_id);
create index if not exists routine_items_created_by_idx
  on public.routine_items (created_by);

create index if not exists shared_reels_added_by_idx
  on public.shared_reels (added_by);
create index if not exists shared_reel_views_user_id_idx
  on public.shared_reel_views (user_id);

create index if not exists watch_sessions_started_by_idx
  on public.watch_sessions (started_by);
