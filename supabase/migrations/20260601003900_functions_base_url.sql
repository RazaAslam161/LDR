-- ───────────────────────────────────────────────────────────────────────────
-- Miles — guard: no notifier may embed a project URL.
--
-- The URL itself moved to configuration in 20260601000150_app_config.sql, and
-- every notifier resolves it through public.functions_base_url() from the
-- moment it is created. This file exists to make the rule enforceable rather
-- than remembered: it fails the replay if a literal project ref ever
-- reappears in a function body.
--
-- Why it matters: four triggers embedded the production ref, so a staging
-- INSERT posted to production's Edge Function and sent real pushes to real
-- users' phones. A restore into a new project would have kept notifying the
-- old one. And because pg_net is fire-and-forget, missing one during a
-- project-ref rotation fails silently.
-- ───────────────────────────────────────────────────────────────────────────

do $do$
declare n int; d text;
begin
  select count(*), coalesce(string_agg(p.proname, ', '), '')
    into n, d
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
   where ns.nspname = 'public'
     and p.prokind = 'f'
     and pg_get_functiondef(p.oid) ~ 'https://[a-z0-9]{20}\.supabase\.co';
  if n > 0 then
    raise exception
      'hardcoded project URL in %: move it to public.functions_base_url()', d;
  end if;
end $do$;
