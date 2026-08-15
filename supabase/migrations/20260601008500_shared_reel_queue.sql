-- The shared reel queue.
--
-- Instagram exposes no feed to any third party, so watching it together inside
-- the app is not buildable at any effort — watch_source.dart:64 already
-- classifies instagram.com as a site that "carries real video but refuses to be
-- embedded". What IS buildable is the part that mattered: she finds a reel,
-- shares it into Miles, and it is waiting for him, with the app remembering
-- which of them has actually seen it.
--
-- Stores a LINK and nothing else. No thumbnail fetch, no page scrape: both
-- would mean this app talking to Instagram on the couple's behalf, which is
-- what gets accounts banned, and neither is needed for the value here.
create table if not exists public.shared_reels (
  id         uuid primary key default gen_random_uuid(),
  couple_id  uuid not null references public.couples(id) on delete cascade,
  added_by   uuid references public.profiles(id) on delete set null,
  url        text not null,
  -- 'Instagram', 'TikTok', 'YouTube'… resolved on the device by the same
  -- parser Watch Together uses, so one place knows what a link is.
  source     text,
  note       text,
  created_at timestamptz not null default now(),
  deleted    boolean not null default false
);

create index if not exists shared_reels_couple_idx
  on public.shared_reels (couple_id, created_at desc) where not deleted;

-- Who has watched what. Its own table rather than a flag, because "have you
-- seen this yet" is per person and knowing whether the OTHER one has is the
-- entire feature.
create table if not exists public.shared_reel_views (
  reel_id  uuid not null references public.shared_reels(id) on delete cascade,
  user_id  uuid not null references public.profiles(id)     on delete cascade,
  seen_at  timestamptz not null default now(),
  primary key (reel_id, user_id)
);

alter table public.shared_reels      enable row level security;
alter table public.shared_reel_views enable row level security;

drop policy if exists shared_reels_member on public.shared_reels;
create policy shared_reels_member on public.shared_reels
  for select using (couple_id = (select public.current_user_couple_id()));
drop policy if exists shared_reels_insert on public.shared_reels;
create policy shared_reels_insert on public.shared_reels
  for insert with check (couple_id = (select public.current_user_couple_id())
                         and added_by = auth.uid());
-- Either partner can clear a link. A shared list of things to watch is
-- housekeeping, not a joint possession — the dual-consent machinery the gallery
-- needs would be ceremony here.
drop policy if exists shared_reels_update on public.shared_reels;
create policy shared_reels_update on public.shared_reels
  for update using (couple_id = (select public.current_user_couple_id()))
          with check (couple_id = (select public.current_user_couple_id()));

drop policy if exists shared_reel_views_member on public.shared_reel_views;
create policy shared_reel_views_member on public.shared_reel_views
  for select using (reel_id in (select id from public.shared_reels
                                where couple_id = (select public.current_user_couple_id())));
drop policy if exists shared_reel_views_own on public.shared_reel_views;
create policy shared_reel_views_own on public.shared_reel_views
  for insert with check (user_id = auth.uid());
drop policy if exists shared_reel_views_own_delete on public.shared_reel_views;
create policy shared_reel_views_own_delete on public.shared_reel_views
  for delete using (user_id = auth.uid());

revoke all on public.shared_reels      from anon;
revoke all on public.shared_reel_views from anon;
revoke truncate, references, trigger on public.shared_reels      from authenticated, anon;
revoke truncate, references, trigger on public.shared_reel_views from authenticated, anon;
revoke delete, update on public.shared_reels from authenticated;
grant select, insert on public.shared_reels to authenticated;
grant update (deleted, note) on public.shared_reels to authenticated;
grant select, insert, delete on public.shared_reel_views to authenticated;

do $do$ begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public'
                    and tablename='shared_reels') then
    alter publication supabase_realtime add table public.shared_reels;
  end if;
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public'
                    and tablename='shared_reel_views') then
    alter publication supabase_realtime add table public.shared_reel_views;
  end if;
end $do$;

do $do$ begin
  if has_table_privilege('authenticated','public.shared_reels','DELETE') then
    raise exception 'shared_reels must be soft-delete only';
  end if;
end $do$;
