-- ───────────────────────────────────────────────────────────────────────────
-- Miles — make account deletion actually possible.
--
-- delete_my_account() deletes auth.users, which cascades to profiles. ANY
-- foreign key referencing profiles (or couples) with NO ACTION aborts that
-- whole transaction. Google Play requires an in-app deletion path that works,
-- and it did not.
--
-- pairing_invites.consumed_by was the first one found and it alone broke
-- deletion for the JOINING partner — exactly one person in every couple, so
-- half of all users. Diffing production afterwards found SIX more, which is
-- the real lesson: this is a class, not an incident, and it recurs every time
-- a feature adds a "who did this" column. The check at the bottom is the
-- durable fix.
--
-- Choice of action per column:
--   nullable attribution  -> SET NULL. The row records something that
--                            happened and outlives the person who did it.
--   NOT NULL attribution  -> CASCADE. Cannot be nulled, and deleting the
--                            person's own content is the right answer to a
--                            deletion request anyway.
-- ───────────────────────────────────────────────────────────────────────────

alter table public.cycle_events
  drop constraint if exists cycle_events_couple_id_fkey;
alter table public.cycle_events
  add constraint cycle_events_couple_id_fkey
  foreign key (couple_id) references public.couples(id) on delete cascade;

alter table public.memory_threads
  drop constraint if exists memory_threads_accepted_by_fkey;
alter table public.memory_threads
  add constraint memory_threads_accepted_by_fkey
  foreign key (accepted_by) references public.profiles(id) on delete set null;

alter table public.vault_items
  drop constraint if exists vault_items_delete_requested_by_fkey;
alter table public.vault_items
  add constraint vault_items_delete_requested_by_fkey
  foreign key (delete_requested_by) references public.profiles(id) on delete set null;

alter table public.vault_items
  drop constraint if exists vault_items_deleted_by_fkey;
alter table public.vault_items
  add constraint vault_items_deleted_by_fkey
  foreign key (deleted_by) references public.profiles(id) on delete set null;

alter table public.vault_items
  drop constraint if exists vault_items_created_by_fkey;
alter table public.vault_items
  add constraint vault_items_created_by_fkey
  foreign key (created_by) references public.profiles(id) on delete cascade;

alter table public.couple_dissolutions
  drop constraint if exists couple_dissolutions_initiated_by_fkey;
alter table public.couple_dissolutions
  add constraint couple_dissolutions_initiated_by_fkey
  foreign key (initiated_by) references public.profiles(id) on delete cascade;

-- RLS already denies every read of app_secrets (it has zero policies, and
-- RLS denies by default — verified by impersonating the role). The default
-- table grant adds nothing but risk: one accidental `create policy` and the
-- Cloudflare TURN token is readable by every signed-up user.
revoke all on public.app_secrets from authenticated, anon;

-- ── The durable fix: fail loudly the next time this class reappears ─────────
-- A new feature that adds `created_by uuid references profiles(id)` without an
-- ON DELETE action silently breaks account deletion again, and nothing
-- surfaces it until a real user tries to delete and the transaction aborts.
do $do$
declare n int; d text;
begin
  select count(*), coalesce(string_agg(conrelid::regclass||'.'||conname, ', '), '')
    into n, d
    from pg_constraint
   where contype = 'f'
     and confrelid in ('public.profiles'::regclass, 'public.couples'::regclass)
     and confdeltype = 'a';
  if n > 0 then
    raise exception 'account deletion is blocked by % foreign key(s) with NO ACTION: %', n, d;
  end if;
end $do$;
