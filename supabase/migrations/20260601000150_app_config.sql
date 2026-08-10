-- ───────────────────────────────────────────────────────────────────────────
-- Miles — per-environment configuration. Must exist before anything that
-- posts to an Edge Function, which is why it sits immediately after schema.
--
-- app_secrets holds values that differ per project and must never be committed:
-- the Cloudflare TURN credentials, and the base URL of this project's Edge
-- Functions.
--
-- RLS is ON with ZERO POLICIES, deliberately. RLS denies by default, so a
-- table with no policy is unreadable by any role that is not the owner — only
-- SECURITY DEFINER functions and the service role (used by the Edge Functions)
-- can read it. Verified by impersonation: `set role authenticated;
-- select count(*) from app_secrets` returns 0. The table grants are revoked as
-- well, so RLS is not the only thing standing between a client role and a
-- billable credential.
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.app_secrets (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);

alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from authenticated, anon;

-- Where this project's Edge Functions live.
--
-- Every push trigger used to embed the literal production project ref, so a
-- staging INSERT posted to production and sent real pushes to real users'
-- phones, and a restore into a new project would have kept notifying the old
-- one. Resolution order: the GUC if an operator set one, else the row in
-- app_secrets. Returns NULL when unconfigured — callers must treat that as
-- "no notification", never as an error, because these run inside AFTER INSERT
-- triggers on the user's own writes.
create or replace function public.functions_base_url()
returns text language plpgsql stable security definer set search_path = public as $fn$
declare v text;
begin
  v := nullif(current_setting('app.functions_base_url', true), '');
  if v is not null then return rtrim(v, '/'); end if;
  select rtrim(value, '/') into v from public.app_secrets
   where key = 'FUNCTIONS_BASE_URL';
  return v;
end $fn$;

revoke execute on function public.functions_base_url() from public, anon, authenticated;

-- ───────────────────────────────────────────────────────────────────────────
-- EACH ENVIRONMENT sets its own values once, by hand. Never committed:
--
--   insert into public.app_secrets (key, value) values
--     ('FUNCTIONS_BASE_URL', 'https://<this-project-ref>.supabase.co'),
--     ('CF_TURN_KEY_ID',     '<cloudflare turn key id>'),
--     ('CF_TURN_API_TOKEN',  '<cloudflare turn api token>')
--   on conflict (key) do update set value = excluded.value, updated_at = now();
--
-- Verify:  select public.functions_base_url();
--          select key, updated_at from public.app_secrets;   -- never value
-- ───────────────────────────────────────────────────────────────────────────
