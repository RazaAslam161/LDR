-- ───────────────────────────────────────────────────────────────────────────
-- Miles — the push endpoint took orders from anyone.
--
-- reach-notify runs with verify_jwt OFF. That is correct: every caller is a
-- database trigger and a trigger carries no JWT. It is also why the endpoint
-- was reachable by the whole internet — it holds the service role, looks up
-- whichever user the body names, and sends them a push. Nothing asked who was
-- calling. On a build that disguises itself as a news app, "your partner is
-- reaching for you" from a stranger is a working phishing channel, and at
-- volume it is free push spam against every user.
--
-- Turning verify_jwt on would have silently killed all notifications instead,
-- which is the trap: the fix has to be a credential a TRIGGER can carry.
--
-- So: a 32-byte secret minted in the database, sent as x-notify-secret by every
-- notifier, checked by the function against the same row before it does
-- anything else.
--
-- The function enforces only when a secret is configured. A fresh project that
-- has not seeded one yet keeps working while it is set up, and an attacker
-- cannot un-set it, so the lenient direction gives nothing away.
--
-- Verified against production after deploying:
--   no secret     -> HTTP 403
--   wrong secret  -> HTTP 403
--   real trigger  -> HTTP 200 {"skipped":"no recipient token"}
-- ───────────────────────────────────────────────────────────────────────────

-- The value itself is per-project and never committed:
--   insert into public.app_secrets (key, value)
--   values ('NOTIFY_SHARED_SECRET', encode(extensions.gen_random_bytes(32),'hex'))
--   on conflict (key) do nothing;

create or replace function public.notify_secret()
returns text language sql stable security definer set search_path = public as $fn$
  select value from public.app_secrets where key = 'NOTIFY_SHARED_SECRET';
$fn$;

revoke execute on function public.notify_secret() from public, anon, authenticated;

-- Rewritten by catalogue rather than by editing four bodies by hand: none can
-- be missed, and re-running covers a notifier added later that copied one of
-- these. Idempotent - a function that already sends the header is skipped.
do $do$
declare r record; src text; new_src text; n int := 0;
begin
  for r in
    select p.oid, p.proname, pg_get_functiondef(p.oid) as def
    from pg_proc p join pg_namespace ns on ns.oid = p.pronamespace
    where ns.nspname = 'public'
      -- prokind: pg_get_functiondef() raises on an aggregate.
      and p.prokind = 'f'
      and pg_get_functiondef(p.oid) like '%functions/v1/reach-notify%'
  loop
    src := r.def;
    if src like '%x-notify-secret%' then continue; end if;
    new_src := replace(src,
      $q$headers := jsonb_build_object('Content-Type', 'application/json')$q$,
      $q$headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', coalesce(public.notify_secret(), ''))$q$);
    if new_src = src then
      raise warning 'could not add the secret header to %', r.proname;
      continue;
    end if;
    execute new_src;
    n := n + 1;
  end loop;
  raise notice 'added the secret header to % notifier(s)', n;
end $do$;
