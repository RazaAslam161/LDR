-- ───────────────────────────────────────────────────────────────────────────
-- Miles — app_secrets, call_signals, cycle_logs.
--
-- RECONSTRUCTED FROM PRODUCTION. The last three tables that existed only in
-- the dashboard. Found by diffing a clean replay against the live database:
-- production has 43 tables, the repo built 40.
--
-- app_secrets is the consequential one. The turn-credentials edge function
-- reads the Cloudflare key id and API token out of it, so on a fresh
-- deployment the table is absent, the function returns turn_not_configured,
-- and CALLING CANNOT WORK AT ALL — with no error anywhere that says why.
--
-- NO SECRET VALUES ARE IN THIS FILE. It creates the table and its protection;
-- the two rows are inserted by hand, per the comment at the bottom.
-- ───────────────────────────────────────────────────────────────────────────

-- ── app_secrets ────────────────────────────────────────────────────────────
create table if not exists public.app_secrets (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);

-- RLS ON with ZERO policies is deliberate and is the whole protection: RLS
-- denies by default, so a table with no policy is unreadable by any role that
-- is not the owner. Verified by impersonation against production —
-- `set role authenticated; select count(*) from app_secrets` returns 0.
--
-- Only SECURITY DEFINER functions and the service role (used by the edge
-- function) can read it, both of which bypass RLS.
alter table public.app_secrets enable row level security;

-- Defence in depth: production still carries the default table grant, so the
-- table is one accidental `create policy` away from exposing the Cloudflare
-- token. RLS is doing the work; the grant adds nothing but risk.
revoke all on public.app_secrets from authenticated, anon;

-- ── call_signals ───────────────────────────────────────────────────────────
create table if not exists public.call_signals (
  id         uuid primary key default gen_random_uuid(),
  couple_id  uuid not null references public.couples(id) on delete cascade,
  from_user  uuid not null references public.profiles(id) on delete cascade,
  to_user    uuid not null references public.profiles(id) on delete cascade,
  type       text not null,
  payload    jsonb not null,
  created_at timestamptz default now()
);

create index if not exists call_signals_couple_created_idx
  on public.call_signals (couple_id, created_at desc);

alter table public.call_signals enable row level security;

drop policy if exists "call_signals_rw" on public.call_signals;
create policy "call_signals_rw" on public.call_signals
  for all using (couple_id = public.current_user_couple_id())
  with check (couple_id = public.current_user_couple_id());

-- ── cycle_logs ─────────────────────────────────────────────────────────────
create table if not exists public.cycle_logs (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  couple_id    uuid not null references public.couples(id) on delete cascade,
  period_start date not null,
  created_at   timestamptz not null default now()
);

create index if not exists cycle_logs_user_start_idx
  on public.cycle_logs (user_id, period_start desc);

alter table public.cycle_logs enable row level security;

drop policy if exists "cycle_logs_owner" on public.cycle_logs;
create policy "cycle_logs_owner" on public.cycle_logs
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists "cycle_logs_partner_read" on public.cycle_logs;
create policy "cycle_logs_partner_read" on public.cycle_logs
  for select using (
    couple_id = public.current_user_couple_id()
    and user_id <> auth.uid()
    and exists (
      select 1 from public.cycle_settings s
       where s.user_id = cycle_logs.user_id and s.share_with_partner
    )
  );

-- ───────────────────────────────────────────────────────────────────────────
-- AFTER THIS RUNS ON A NEW ENVIRONMENT, calling stays broken until the two
-- Cloudflare rows exist. They are credentials and must never be committed:
--
--   insert into public.app_secrets (key, value) values
--     ('CF_TURN_KEY_ID',    '<cloudflare turn key id>'),
--     ('CF_TURN_API_TOKEN', '<cloudflare turn api token>');
--
-- Verify with: select key, updated_at from public.app_secrets;  -- never value
-- ───────────────────────────────────────────────────────────────────────────
