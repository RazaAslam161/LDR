-- ───────────────────────────────────────────────────────────────────────────
-- Miles — the thing this app never had: a way to make a breaking change.
--
-- Tethered is sideloaded. No store, no update prompt, no channel that pushes a
-- build. So "change the server once everyone has updated" describes an event
-- that DOES NOT HAPPEN: past a handful of users some fraction is always months
-- behind, permanently.
--
-- That is not abstract. Closing the public couple_media bucket sat blocked on
-- exactly this reasoning — waiting on an install day that exists for two test
-- phones and never for a fleet. The bucket would have stayed public forever,
-- and the plan would have looked responsible the whole time.
--
-- With this, a breaking change is three steps instead of a standoff:
--   1. ship a build that tolerates the change
--   2. raise min_build
--   3. make the change
-- Anyone below min_build is told to update, rather than meeting the change as
-- whatever broken screen it happens to produce.
--
-- Readable by anon deliberately: the check runs BEFORE sign-in, because an
-- out-of-date build may be broken in ways that stop it reaching a session.
-- Nothing here is private, and a gate nobody can read is a gate that fails open
-- in the wrong direction.
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.app_release (
  -- Single row, enforced by the type: `id boolean primary key check (id)` can
  -- only ever hold one true.
  id           boolean primary key default true check (id),
  min_build    integer not null default 1,
  latest_build integer not null default 1,
  message      text,
  updated_at   timestamptz not null default now()
);

insert into public.app_release (id, min_build, latest_build, message)
values (true, 1, 1, 'A newer version of the app is required.')
on conflict (id) do nothing;

alter table public.app_release enable row level security;

drop policy if exists app_release_read on public.app_release;
create policy app_release_read on public.app_release
  for select to anon, authenticated using (true);

revoke insert, update, delete, truncate, trigger, references
  on public.app_release from anon, authenticated;
