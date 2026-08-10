-- ───────────────────────────────────────────────────────────────────────────
-- Miles — cycle tracking and love reasons.
--
-- RECONSTRUCTED FROM PRODUCTION, not inferred. These three tables existed only
-- in the production dashboard; every column, type, default, constraint and
-- policy below was read out of the live database, so this file describes what
-- is actually there rather than what the client implies.
--
-- They are the SILENT version of the care_nudges failure: no migration
-- references them, so a replay succeeds without them and the app breaks only
-- when a real user opens Cycle or Love Reasons on a fresh deployment.
--
-- ONE DELIBERATE DIVERGENCE FROM PRODUCTION, marked below: production's
-- cycle_events.couple_id foreign key has no ON DELETE action. That is the same
-- defect that made account deletion impossible for the joining partner
-- (pairing_invites.consumed_by), and it is reproduced here as CASCADE instead.
-- Production should be corrected to match; the conformance check will flag it
-- until it is.
-- ───────────────────────────────────────────────────────────────────────────

-- ── cycle_settings — one row per user, PK is user_id (no surrogate id) ──────
create table if not exists public.cycle_settings (
  user_id            uuid primary key references public.profiles(id) on delete cascade,
  couple_id          uuid references public.couples(id) on delete cascade,
  avg_cycle_length   integer not null default 28,
  avg_period_length  integer not null default 5,
  share_with_partner boolean not null default true,
  updated_at         timestamptz not null default now(),
  on_period_now      boolean not null default false,
  tracking_enabled   boolean not null default false
);

alter table public.cycle_settings enable row level security;

drop policy if exists "cycle_settings_own" on public.cycle_settings;
create policy "cycle_settings_own" on public.cycle_settings
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "cycle_settings_partner_read" on public.cycle_settings;
create policy "cycle_settings_partner_read" on public.cycle_settings
  for select using (couple_id = public.current_user_couple_id());

-- ── cycle_events ───────────────────────────────────────────────────────────
create table if not exists public.cycle_events (
  id         uuid primary key default gen_random_uuid(),
  -- DIVERGENCE: production has FOREIGN KEY (couple_id) REFERENCES couples(id)
  -- with no ON DELETE action, so a couple carrying cycle events cannot be
  -- deleted — which means delete_my_account fails for that user, exactly as it
  -- did for the joining partner via pairing_invites.consumed_by.
  couple_id  uuid references public.couples(id) on delete cascade,
  user_id    uuid references public.profiles(id) on delete cascade,
  type       text not null check (type in ('period_start', 'period_end')),
  event_date date not null,
  created_at timestamptz default now()
);

create index if not exists cycle_events_user_date_idx
  on public.cycle_events (user_id, event_date desc);

alter table public.cycle_events enable row level security;

drop policy if exists "cycle_events_own" on public.cycle_events;
create policy "cycle_events_own" on public.cycle_events
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

-- The partner sees your events only while you are sharing. The share flag is
-- read inside the policy, so revoking it takes effect immediately rather than
-- when the client next decides to hide them.
drop policy if exists "cycle_events_partner_read" on public.cycle_events;
create policy "cycle_events_partner_read" on public.cycle_events
  for select using (
    couple_id = public.current_user_couple_id()
    and user_id <> auth.uid()
    and exists (
      select 1 from public.cycle_settings s
       where s.user_id = cycle_events.user_id and s.share_with_partner
    )
  );

-- ── love_reasons ───────────────────────────────────────────────────────────
create table if not exists public.love_reasons (
  id         uuid primary key default gen_random_uuid(),
  couple_id  uuid not null references public.couples(id) on delete cascade,
  author     uuid not null references public.profiles(id) on delete cascade,
  text       text not null,
  created_at timestamptz not null default now()
);

create index if not exists love_reasons_couple_created_idx
  on public.love_reasons (couple_id, created_at desc);

alter table public.love_reasons enable row level security;

drop policy if exists "love_reasons_select_member" on public.love_reasons;
create policy "love_reasons_select_member" on public.love_reasons
  for select using (couple_id = public.current_user_couple_id());

drop policy if exists "love_reasons_insert_self" on public.love_reasons;
create policy "love_reasons_insert_self" on public.love_reasons
  for insert with check (
    couple_id = public.current_user_couple_id() and author = auth.uid()
  );

-- Only the author may delete their own reason. Matches production: there is no
-- UPDATE policy, so a reason is write-once by construction.
drop policy if exists "love_reasons_delete_own" on public.love_reasons;
create policy "love_reasons_delete_own" on public.love_reasons
  for delete using (author = auth.uid());
