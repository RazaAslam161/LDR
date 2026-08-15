-- What the couple is watching, held server-side.
--
-- It used to live in _WatchTogetherScreenState and nowhere else, so the whole
-- session was disposed the moment either of them navigated away — the link
-- vanished for BOTH, mid-video, because one person checked a message. And a
-- partner who opened the screen a minute late arrived to an empty box: the
-- `load` broadcast had already been delivered to nobody.
--
-- A broadcast is a message to whoever is listening RIGHT NOW. A session is a
-- fact that outlives both of their attention spans, so it belongs in a row.
--
-- One row per couple. A second link replaces the first, which is what picking
-- something else already means, and it closes when somebody closes it — not
-- when either of them looks away.
create table if not exists public.watch_sessions (
  couple_id  uuid primary key references public.couples(id) on delete cascade,
  -- The wire key: a YouTube id, or a canonical https URL. Exactly what
  -- watch_source.sourceFromKey round-trips, so the two devices rebuild the
  -- same WatchSource from it rather than re-parsing a link twice.
  source_key text not null,
  kind       text not null,
  site       text,
  start_ms   int  not null default 0,
  started_by uuid references public.profiles(id) on delete set null,
  started_at timestamptz not null default now()
);

alter table public.watch_sessions enable row level security;

drop policy if exists watch_sessions_member on public.watch_sessions;
create policy watch_sessions_member on public.watch_sessions
  for select using (couple_id = (select public.current_user_couple_id()));
drop policy if exists watch_sessions_write on public.watch_sessions;
create policy watch_sessions_write on public.watch_sessions
  for insert with check (couple_id = (select public.current_user_couple_id())
                         and started_by = auth.uid());
drop policy if exists watch_sessions_update on public.watch_sessions;
create policy watch_sessions_update on public.watch_sessions
  for update using (couple_id = (select public.current_user_couple_id()))
          with check (couple_id = (select public.current_user_couple_id()));
-- Either of them may close it. Insisting only the host can would strand the
-- other one behind a link nobody is watching once the host's phone dies.
drop policy if exists watch_sessions_close on public.watch_sessions;
create policy watch_sessions_close on public.watch_sessions
  for delete using (couple_id = (select public.current_user_couple_id()));

revoke all on public.watch_sessions from anon;
revoke truncate, references, trigger on public.watch_sessions from authenticated, anon;
grant select, insert, update, delete on public.watch_sessions to authenticated;

do $do$ begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public'
                    and tablename='watch_sessions') then
    alter publication supabase_realtime add table public.watch_sessions;
  end if;
end $do$;
