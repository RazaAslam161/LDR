-- Two presence oracles, both reachable with nothing but the partner's own JWT
-- and neither of them going anywhere near the call UI.
--
-- 1. reach-notify nulls profiles.fcm_token when FCM answers UNREGISTERED, and
--    fetchPartner selects every column. So the caller watches fcm_token go
--    non-null -> null as a direct consequence of their own call: "their app has
--    been uninstalled, reinstalled, or had its data cleared", delivered on
--    demand, one call at a time. The nulling itself is correct behaviour — a
--    dead token should stop being retried — it just must not be recorded
--    somewhere the other partner can read. It moves here.
--
-- 2. diag_events is readable by both partners. The comment on the original
--    policy justified it ("a call fails because of what happened on the OTHER
--    phone") and that is exactly the problem: the callee uploads accept,
--    accept_failed, teardown-with-from_state, lifecycle. Every row is stamped
--    on ServerClock so it lines up with the caller's own tap, which makes the
--    trace a decline log. Diagnostics has been removed from the client, so
--    narrowing this costs nothing that still exists.

create table if not exists public.push_failures (
  id           bigserial primary key,
  user_id      uuid not null references auth.users(id) on delete cascade,
  kind         text not null,
  status       int,
  reason       text,
  failed_at    timestamptz not null default now()
);

comment on table public.push_failures is
  'Dead-token and send-failure record for reach-notify. Service-role only: the '
  'whole point is that a failure to reach a handset is not observable by the '
  'other member of the couple.';

create index if not exists push_failures_user_at_idx
  on public.push_failures (user_id, failed_at desc);

alter table public.push_failures enable row level security;

-- Deny-all on both layers, not just RLS. A table created without this carries
-- Supabase's default arwdDxtm for anon and authenticated, so RLS is the only
-- thing standing between a probe and the rows — which is one layer, and was
-- the exact shape of the ops_job_runs finding.
revoke all on public.push_failures from anon, authenticated;
revoke all on sequence public.push_failures_id_seq from anon, authenticated;

-- diag_events: own rows only.
drop policy if exists diag_read_couple on public.diag_events;

create policy diag_read_own on public.diag_events
  for select
  using (user_id = (select auth.uid()));

comment on policy diag_read_own on public.diag_events is
  'Own rows only. Cross-device correlation is a service_role query run outside '
  'the app, not a capability either partner holds over the other.';
