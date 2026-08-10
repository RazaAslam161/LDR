-- ───────────────────────────────────────────────────────────────────────────
-- Miles — Chat (messages). Run AFTER schema.sql.
-- Couple-scoped real-time chat. `image_path`/`kind` are forward-compat for
-- photo messages (Supabase Storage) shipping next.
-- ───────────────────────────────────────────────────────────────────────────
create table if not exists public.messages (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  sender_id   uuid not null references public.profiles(id) on delete cascade,
  body        text,
  image_path  text,
  kind        text not null default 'text',   -- 'text' | 'image'
  created_at  timestamptz not null default now()
);
create index if not exists messages_couple_created_idx
  on public.messages(couple_id, created_at);

alter table public.messages enable row level security;

drop policy if exists "messages_select_member" on public.messages;
create policy "messages_select_member" on public.messages
  for select using (couple_id = public.current_user_couple_id());

drop policy if exists "messages_insert_member" on public.messages;
create policy "messages_insert_member" on public.messages
  for insert with check (
    couple_id = public.current_user_couple_id() and sender_id = auth.uid()
  );

drop policy if exists "messages_delete_own" on public.messages;
create policy "messages_delete_own" on public.messages
  for delete using (sender_id = auth.uid());

-- Realtime delivery.
alter table public.messages replica identity full;
do $$ begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname='supabase_realtime' and schemaname='public' and tablename='messages'
  ) then
    alter publication supabase_realtime add table public.messages;
  end if;
end $$;
