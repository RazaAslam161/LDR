-- ───────────────────────────────────────────────────────────────────────────
-- Tethered — FCM push for Reach (Phase 2 + 5). Run AFTER schema.sql + reach_events.sql.
-- Device token storage + the webhook that fires the reach-notify Edge Function.
-- ───────────────────────────────────────────────────────────────────────────

-- Phase 2.1: where each device's FCM token lives (cleared to null on sign-out).
alter table public.profiles add column if not exists fcm_token text;
alter table public.profiles add column if not exists fcm_token_updated_at timestamptz;
-- (RLS: existing profiles_update_self lets a user write only their own row.)

-- Phase 5.3: webhook on reach_events INSERT → reach-notify Edge Function (FCM v1).
-- Implemented with pg_net directly (transparent + version-controlled) instead of
-- a dashboard Database Webhook. The Edge Function accepts the raw row as its body.
create extension if not exists pg_net;

create or replace function public.notify_reach()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform net.http_post(
    url := 'https://sopictusdonlvuezmfep.supabase.co/functions/v1/reach-notify',
    body := to_jsonb(new),
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  return new;
end;
$$;

drop trigger if exists reach_notify_on_insert on public.reach_events;
create trigger reach_notify_on_insert
after insert on public.reach_events
for each row execute function public.notify_reach();

-- The Edge Function itself: supabase/functions/reach-notify/index.ts
-- Required secrets (set by the operator, never committed):
--   supabase secrets set FCM_SERVICE_ACCOUNT="$(cat service-account.json)"
--   supabase secrets set FCM_PROJECT_ID="<firebase-project-id>"
