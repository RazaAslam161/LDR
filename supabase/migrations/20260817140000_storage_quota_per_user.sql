-- Per-user storage quota (5 GB), enforced server-side across EVERY bucket.
--
-- Supabase has no per-user quota. A bucket carries a per-FILE limit and the
-- plan carries a per-PROJECT total; nothing sits between them, so one account
-- can consume the whole project's storage and every other user discovers it as
-- an upload that fails for no reason they can see.
--
-- WHY THIS SHAPE, and not the two obvious ones:
--
-- 1. NOT a trigger on storage.objects. Supabase owns that table:
--      ERROR: 42501: must be owner of table objects
--    Policies on it ARE permitted (the personal_vault_* policies live there),
--    so enforcement goes in a RESTRICTIVE policy instead. Restrictive policies
--    are ANDed with the permissive ones, so this cannot be bypassed by any
--    bucket's own policy being more generous.
--
-- 2. NOT sum(size) inside that policy. storage.objects has no index on `owner`
--    and one cannot be created (same ownership error), so summing would seq
--    scan the whole table on every single upload. The policy reads a counter by
--    primary key instead — O(1) — and a cron job keeps the counter true.
--
-- The counter can lag its cron interval, so a user can overshoot by at most the
-- uploads they manage inside five minutes, bounded by the per-file limit. That
-- is the correct trade for a soft quota: the alternative is a seq scan on the
-- one operation users actually wait for.
--
-- Attribution is `storage.objects.owner` — the auth.uid() that uploaded the
-- object — not the path. Path attribution only works for personal_vault
-- (`<uid>/vault/...`); couple buckets are couple-scoped, and there the uploader
-- is the right person to bill.
--
-- RE-RUNNABLE: applying this twice is a no-op. The seed RECOMPUTES rather than
-- accumulating, which is the difference between a second run being harmless and
-- a second run locking every user out of an app that worked yesterday.
--
-- ROLLBACK (paste to revert; safe at any point, restores unlimited-per-user):
--   drop policy if exists storage_quota_limit on storage.objects;
--   select cron.unschedule('reconcile-storage-usage');
--   drop function if exists public.storage_quota_ok(uuid);
--   drop function if exists public.reconcile_storage_usage();
--   drop function if exists public.storage_quota_bytes();
--   drop table if exists public.storage_usage;

-- ── The limit, in ONE place ────────────────────────────────────────────────
-- 5 GB. Written as a bigint literal deliberately: `(5 * 1024 * 1024 * 1024)::bigint`
-- looks right and raises 22003 `integer out of range`, because Postgres
-- multiplies the int4 literals FIRST and only casts the result — and 5 GB is
-- past int4's 2147483647. The cast cannot save an expression that already
-- overflowed. Caught by the negative test below; without it this would have
-- shipped a policy that rejects every upload in every bucket, since the
-- enforcement path calls this function on every insert.
create or replace function public.storage_quota_bytes()
returns bigint language sql immutable
as $$ select 5368709120::bigint $$;   -- 5 * 1024^3

comment on function public.storage_quota_bytes() is
  'Per-user storage ceiling in bytes, across all buckets. Change here only.';

-- ── The counter ────────────────────────────────────────────────────────────
create table if not exists public.storage_usage (
  user_id     uuid primary key references auth.users(id) on delete cascade,
  bytes       bigint      not null default 0 check (bytes >= 0),
  updated_at  timestamptz not null default now()
);

alter table public.storage_usage enable row level security;

-- A user reads their own usage (so the app can show "3.1 GB of 5 GB") and
-- nothing else. Writes come only from the definer functions below.
drop policy if exists storage_usage_own_read on public.storage_usage;
create policy storage_usage_own_read
  on public.storage_usage for select
  using (user_id = (select auth.uid()));

-- ── Keep it true ───────────────────────────────────────────────────────────
-- Full recompute, not a delta. A delta cannot self-heal: one missed object and
-- the number is wrong forever, drifting toward either a free ride or a lockout.
-- This is a single grouped scan a few times an hour, off the upload path.
create or replace function public.reconcile_storage_usage()
returns integer
language plpgsql
security definer
set search_path to 'public', 'storage'
as $$
declare v_rows integer;
begin
  insert into public.storage_usage (user_id, bytes, updated_at)
  select o.owner, coalesce(sum((o.metadata->>'size')::bigint), 0), now()
    from storage.objects o
   where o.owner is not null
   group by o.owner
  on conflict (user_id) do update
    set bytes = excluded.bytes, updated_at = now();

  get diagnostics v_rows = row_count;

  -- Someone who deleted everything still owns a stale row saying otherwise.
  update public.storage_usage u
     set bytes = 0, updated_at = now()
   where u.bytes <> 0
     and not exists (select 1 from storage.objects o where o.owner = u.user_id);

  return v_rows;
end;
$$;

comment on function public.reconcile_storage_usage() is
  'Recomputes per-user storage bytes from storage.objects. Run by cron; safe to call by hand.';

-- ── Enforce ────────────────────────────────────────────────────────────────
-- Reads the counter by primary key. `stable` so it is evaluated once per
-- statement rather than per row.
create or replace function public.storage_quota_ok(p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select coalesce(
           (select bytes from public.storage_usage where user_id = p_owner),
           0
         ) < public.storage_quota_bytes();
$$;

-- RESTRICTIVE: ANDed with every permissive policy on the table, so no bucket's
-- own policy can grant around it. `owner is null` passes through — service-role
-- and server-side writes are not user uploads and are not billed to anyone.
drop policy if exists storage_quota_limit on storage.objects;
create policy storage_quota_limit
  on storage.objects
  as restrictive
  for insert
  with check (owner is null or public.storage_quota_ok(owner));

-- ── Schedule ───────────────────────────────────────────────────────────────
-- unschedule-then-schedule so a second apply replaces rather than duplicates.
-- Wrapped because unschedule throws when the job does not exist yet, which is
-- the normal case on a first run.
do $$
begin
  begin
    perform cron.unschedule('reconcile-storage-usage');
  exception when others then
    null;  -- no such job yet
  end;
  perform cron.schedule(
    'reconcile-storage-usage',
    '*/5 * * * *',
    $cron$ select public.reconcile_storage_usage(); $cron$
  );
end $$;

-- ── Seed now, so the policy is not enforcing against zeroes ────────────────
select public.reconcile_storage_usage();

do $$
declare v_users int; v_bytes bigint; v_job int;
begin
  select count(*), coalesce(sum(bytes), 0) into v_users, v_bytes
    from public.storage_usage;
  select count(*) into v_job
    from cron.job where jobname = 'reconcile-storage-usage';
  if v_job <> 1 then
    raise exception 'reconcile-storage-usage cron job was not created';
  end if;
  raise notice 'storage_usage seeded: % users, % bytes; cron job present', v_users, v_bytes;
end $$;
