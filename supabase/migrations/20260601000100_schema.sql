-- ───────────────────────────────────────────────────────────────────────────
-- Miles — schema + RLS
-- Run this in the Supabase SQL editor for your project:
--   Dashboard → SQL → New query → paste → Run
-- ───────────────────────────────────────────────────────────────────────────

-- ─── Extensions ────────────────────────────────────────────────────────────
create extension if not exists "pgcrypto";

-- ─── Enums ─────────────────────────────────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_type where typname = 'presence_status') then
    create type presence_status as enum ('asleep', 'awake', 'work', 'free', 'busy');
  end if;
  if not exists (select 1 from pg_type where typname = 'ritual_type') then
    create type ritual_type as enum ('goodnight', 'goodmorning', 'weekly_highlow', 'custom');
  end if;
end $$;

-- ─── Tables ────────────────────────────────────────────────────────────────
create table if not exists public.couples (
  id               uuid primary key default gen_random_uuid(),
  created_at       timestamptz not null default now(),
  invite_code      text not null unique,
  name             text,
  primary_tz       text,
  stripe_customer_id text
);

create table if not exists public.profiles (
  id               uuid primary key references auth.users(id) on delete cascade,
  couple_id        uuid references public.couples(id) on delete set null,
  display_name     text not null,
  avatar_url       text,
  timezone         text not null,
  wake_time        time,
  sleep_time       time,
  presence_status  presence_status not null default 'free',
  created_at       timestamptz not null default now()
);

create table if not exists public.visits (
  id               uuid primary key default gen_random_uuid(),
  couple_id        uuid not null references public.couples(id) on delete cascade,
  start_date       timestamptz not null,
  end_date         timestamptz,
  location         text,
  note             text,
  is_upcoming      boolean not null default true,
  created_at       timestamptz not null default now()
);
create index if not exists visits_couple_id_idx        on public.visits(couple_id);
create index if not exists visits_upcoming_idx          on public.visits(couple_id, is_upcoming, start_date);

create table if not exists public.daily_prompts (
  id               uuid primary key default gen_random_uuid(),
  prompt_text      text not null,
  scheduled_date   date not null,
  couple_id        uuid not null references public.couples(id) on delete cascade,
  unique (couple_id, scheduled_date)
);

create table if not exists public.prompt_responses (
  id               uuid primary key default gen_random_uuid(),
  prompt_id        uuid not null references public.daily_prompts(id) on delete cascade,
  user_id          uuid not null references public.profiles(id) on delete cascade,
  response_text    text,
  responded_at     timestamptz not null default now(),
  unique (prompt_id, user_id)
);

create table if not exists public.rituals (
  id               uuid primary key default gen_random_uuid(),
  couple_id        uuid not null references public.couples(id) on delete cascade,
  type             ritual_type not null,
  cron             text,
  message          text,
  deliver_at       timestamptz,
  delivered        boolean not null default false
);
create index if not exists rituals_pending_idx on public.rituals(delivered, deliver_at);

create table if not exists public.visit_memories (
  id               uuid primary key default gen_random_uuid(),
  visit_id         uuid not null references public.visits(id) on delete cascade,
  photo_url        text,
  caption          text,
  created_at       timestamptz not null default now()
);

-- ─── Row Level Security ────────────────────────────────────────────────────
-- Core rule: a user can only touch rows belonging to a couple they're a member of.

alter table public.couples           enable row level security;
alter table public.profiles          enable row level security;
alter table public.visits            enable row level security;
alter table public.daily_prompts     enable row level security;
alter table public.prompt_responses  enable row level security;
alter table public.rituals           enable row level security;
alter table public.visit_memories    enable row level security;

-- Helper: returns the couple_id for the current user, or NULL.
-- (Inlining the lookup avoids extra round-trips per policy.)
create or replace function public.current_user_couple_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select couple_id from public.profiles where id = auth.uid();
$$;

-- Profiles: a user can read their own profile + their partner's, update only their own.
drop policy if exists "profiles_select_self_or_partner" on public.profiles;
create policy "profiles_select_self_or_partner" on public.profiles
  for select using (
    id = auth.uid() or couple_id = public.current_user_couple_id()
  );

drop policy if exists "profiles_insert_self" on public.profiles;
create policy "profiles_insert_self" on public.profiles
  for insert with check (id = auth.uid());

drop policy if exists "profiles_update_self" on public.profiles;
create policy "profiles_update_self" on public.profiles
  for update using (id = auth.uid()) with check (id = auth.uid());

-- Couples: readable by members only. Creating/joining is done through the
-- SECURITY DEFINER RPCs below (create_couple / join_couple_by_code) so we never
-- need a self-referential SELECT policy here (that caused 42P17 recursion).
drop policy if exists "couples_select_member" on public.couples;
create policy "couples_select_member" on public.couples
  for select using (id = public.current_user_couple_id());

drop policy if exists "couples_insert_authed" on public.couples;
create policy "couples_insert_authed" on public.couples
  for insert with check (auth.uid() is not null);

-- A member can update their own couple (e.g. setting stripe_customer_id).
drop policy if exists "couples_update_member" on public.couples;
create policy "couples_update_member" on public.couples
  for update using (id = public.current_user_couple_id())
  with check (id = public.current_user_couple_id());

-- For the remaining couple-scoped tables, the policy is the same:
--   read/select requires couple membership,
--   write (insert/update/delete) requires couple membership.
do $$
declare
  t text;
begin
  -- Only couple_id-bearing tables go through this generic loop.
  -- prompt_responses (links via prompt_id) and visit_memories (links via
  -- visit_id) have NO couple_id column and get explicit policies below.
  foreach t in array array[
    'visits',
    'daily_prompts',
    'rituals'
  ]
  loop
    execute format('drop policy if exists "%1$s_select_member" on public.%1$s;', t);
    execute format(
      'create policy "%1$s_select_member" on public.%1$s for select using (couple_id = public.current_user_couple_id());',
      t
    );

    execute format('drop policy if exists "%1$s_insert_member" on public.%1$s;', t);
    execute format(
      'create policy "%1$s_insert_member" on public.%1$s for insert with check (couple_id = public.current_user_couple_id());',
      t
    );

    execute format('drop policy if exists "%1$s_update_member" on public.%1$s;', t);
    execute format(
      'create policy "%1$s_update_member" on public.%1$s for update using (couple_id = public.current_user_couple_id()) with check (couple_id = public.current_user_couple_id());',
      t
    );

    execute format('drop policy if exists "%1$s_delete_member" on public.%1$s;', t);
    execute format(
      'create policy "%1$s_delete_member" on public.%1$s for delete using (couple_id = public.current_user_couple_id());',
      t
    );
  end loop;
end $$;

-- Special case: visit_memories has no couple_id column — its policy joins via visit.
drop policy if exists "visit_memories_select_member" on public.visit_memories;
create policy "visit_memories_select_member" on public.visit_memories
  for select using (
    visit_id in (
      select v.id from public.visits v
      where v.couple_id = public.current_user_couple_id()
    )
  );

drop policy if exists "visit_memories_insert_member" on public.visit_memories;
create policy "visit_memories_insert_member" on public.visit_memories
  for insert with check (
    visit_id in (
      select v.id from public.visits v
      where v.couple_id = public.current_user_couple_id()
    )
  );

drop policy if exists "visit_memories_update_member" on public.visit_memories;
create policy "visit_memories_update_member" on public.visit_memories
  for update using (
    visit_id in (
      select v.id from public.visits v
      where v.couple_id = public.current_user_couple_id()
    )
  );

drop policy if exists "visit_memories_delete_member" on public.visit_memories;
create policy "visit_memories_delete_member" on public.visit_memories
  for delete using (
    visit_id in (
      select v.id from public.visits v
      where v.couple_id = public.current_user_couple_id()
    )
  );

-- prompt_responses has user_id + prompt_id, not couple_id. Gate every action
-- through the parent prompt's couple. The SELECT policy is what makes the
-- "reveal both answers" flow work (was missing, so reads returned nothing).
drop policy if exists "prompt_responses_select_member" on public.prompt_responses;
create policy "prompt_responses_select_member" on public.prompt_responses
  for select using (
    prompt_id in (
      select p.id from public.daily_prompts p
      where p.couple_id = public.current_user_couple_id()
    )
  );

drop policy if exists "prompt_responses_insert_member" on public.prompt_responses;
create policy "prompt_responses_insert_member" on public.prompt_responses
  for insert with check (
    user_id = auth.uid()
    and prompt_id in (
      select p.id from public.daily_prompts p
      where p.couple_id = public.current_user_couple_id()
    )
  );

-- A user may update their own response (the screen upserts on re-answer).
drop policy if exists "prompt_responses_update_self" on public.prompt_responses;
create policy "prompt_responses_update_self" on public.prompt_responses
  for update using (user_id = auth.uid())
  with check (
    user_id = auth.uid()
    and prompt_id in (
      select p.id from public.daily_prompts p
      where p.couple_id = public.current_user_couple_id()
    )
  );

-- A user may delete their own response.
drop policy if exists "prompt_responses_delete_self" on public.prompt_responses;
create policy "prompt_responses_delete_self" on public.prompt_responses
  for delete using (user_id = auth.uid());

-- ─── Auto-create profile on signup ─────────────────────────────────────────
-- Mirrors the Supabase "handle_new_user" trigger pattern.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, display_name, timezone)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
    'UTC'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ─── Couple create / join RPCs (SECURITY DEFINER) ──────────────────────────
-- These replace the old client-side "insert couple then select it" flow, which
-- tripped the recursive RLS policy. Both run as definer and link the caller's
-- profile atomically.

create or replace function public.create_couple(p_timezone text)
returns public.couples
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_code   text;
  v_couple public.couples;
  v_try    int := 0;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  -- Idempotent: if already linked, return the existing couple.
  select c.* into v_couple
  from public.couples c
  join public.profiles p on p.couple_id = c.id
  where p.id = v_uid;
  if found then return v_couple; end if;

  loop
    v_try := v_try + 1;
    v_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 6));
    begin
      insert into public.couples (invite_code, primary_tz)
      values (v_code, p_timezone)
      returning * into v_couple;
      exit;
    exception when unique_violation then
      if v_try >= 6 then raise; end if;
    end;
  end loop;

  update public.profiles set couple_id = v_couple.id where id = v_uid;
  return v_couple;
end;
$$;

create or replace function public.join_couple_by_code(p_code text)
returns public.couples
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_clean  text := upper(regexp_replace(coalesce(p_code,''), '\s', '', 'g'));
  v_couple public.couples;
  v_count  int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;

  select * into v_couple from public.couples where invite_code = v_clean;
  if not found then raise exception 'invalid_code'; end if;

  select count(*) into v_count from public.profiles where couple_id = v_couple.id;
  if v_count >= 2 then raise exception 'couple_full'; end if;

  update public.profiles set couple_id = v_couple.id where id = v_uid;
  return v_couple;
end;
$$;

-- ─── Execute grants (keep helper/trigger fns off the anon REST surface) ─────
revoke execute on function public.create_couple(text)        from public, anon;
grant  execute on function public.create_couple(text)        to authenticated;
revoke execute on function public.join_couple_by_code(text)  from public, anon;
grant  execute on function public.join_couple_by_code(text)  to authenticated;
revoke execute on function public.current_user_couple_id()   from public, anon;
grant  execute on function public.current_user_couple_id()   to authenticated;
revoke execute on function public.handle_new_user()          from public, anon, authenticated;
