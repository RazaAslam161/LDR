-- ───────────────────────────────────────────────────────────────────────────
-- Miles — care nudges ("eat lunch", "take your medicine").
--
-- RECONSTRUCTED. This table existed only in the production dashboard: no file
-- in this repo created it, so a fresh database had nothing for
-- care_call_push.sql's trigger to attach to, and the first staging replay
-- stopped here with "relation public.care_nudges does not exist".
--
-- The shape is derived from the only two things that constrain it — the client
-- at mobile/lib/features/care/care_repository.dart (which reads id, couple_id,
-- from_user, kind, message, created_at, acknowledged_at and subscribes to
-- postgres_changes filtered on couple_id) and care_call_push.sql's trigger
-- (which posts to_jsonb(new) and needs from_user + couple_id present).
--
-- VERIFY AGAINST PRODUCTION before trusting this to describe the live table:
--   select column_name, data_type, is_nullable, column_default
--     from information_schema.columns
--    where table_schema = 'public' and table_name = 'care_nudges'
--    order by ordinal_position;
-- If production differs, production is the truth and this file is wrong.
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.care_nudges (
  id              uuid primary key default gen_random_uuid(),
  couple_id       uuid not null references public.couples(id) on delete cascade,
  from_user       uuid not null references public.profiles(id) on delete cascade,
  kind            text not null,
  message         text not null,
  -- Server-stamped. A client-settable created_at makes a row immortal to any
  -- retention sweep keyed on it, and this table is swept.
  created_at      timestamptz not null default now(),
  acknowledged_at timestamptz
);

create index if not exists care_nudges_couple_created_idx
  on public.care_nudges (couple_id, created_at desc);

alter table public.care_nudges enable row level security;

-- Couple-scoped read. Without this the table was readable by any signed-in
-- user, since Postgres grants SELECT to authenticated by default and no policy
-- existed to narrow it.
drop policy if exists "care_nudges_select_member" on public.care_nudges;
create policy "care_nudges_select_member" on public.care_nudges
  for select using (couple_id = public.current_user_couple_id());

-- You may only send as yourself, into your own couple.
drop policy if exists "care_nudges_insert_self" on public.care_nudges;
create policy "care_nudges_insert_self" on public.care_nudges
  for insert with check (
    from_user = auth.uid() and couple_id = public.current_user_couple_id()
  );

-- Either partner may acknowledge — the RECIPIENT is the one who marks it done,
-- so this cannot be restricted to the author.
drop policy if exists "care_nudges_update_member" on public.care_nudges;
create policy "care_nudges_update_member" on public.care_nudges
  for update using (couple_id = public.current_user_couple_id())
  with check (couple_id = public.current_user_couple_id());

drop policy if exists "care_nudges_delete_member" on public.care_nudges;
create policy "care_nudges_delete_member" on public.care_nudges
  for delete using (couple_id = public.current_user_couple_id());

-- acknowledged_at is the only field the client updates after insert; every
-- other column is write-once. Revoking the table grant and re-granting one
-- column is the only form that actually restricts — a bare column-level
-- REVOKE cannot narrow a table-level grant and silently does nothing.
revoke update on public.care_nudges from authenticated, anon;
grant update (acknowledged_at) on public.care_nudges to authenticated;

-- The client subscribes with postgres_changes filtered on couple_id. Without
-- the publication it receives nothing; without REPLICA IDENTITY FULL an
-- RLS-filtered UPDATE arrives lacking the columns needed to evaluate the
-- filter and is dropped.
alter table public.care_nudges replica identity full;
do $do$
begin
  if not exists (
    select 1 from pg_publication_tables
     where pubname = 'supabase_realtime'
       and schemaname = 'public' and tablename = 'care_nudges'
  ) then
    alter publication supabase_realtime add table public.care_nudges;
  end if;
end $do$;
