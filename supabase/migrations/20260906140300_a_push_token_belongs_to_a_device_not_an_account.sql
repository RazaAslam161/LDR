-- A push token belongs to a device, not to an account.
--
-- profiles.fcm_token is one slot per account: the last handset to register
-- wins and the other goes quiet, "sign out of other devices" never touched it
-- (the lost phone kept receiving), and the slot cannot say when its token has
-- died. Production's push_failures holds 131 'unregistered' rows over the last
-- fourteen days against ONE token that the client re-uploads on every resume:
-- from the handset the registration looks fine, and nothing on the server may
-- null the column (build 73's fetchPartner selects it whole, so a server-side
-- null is a presence oracle - 20260601005850).
--
-- push_tokens is the ledger: one row per (account, install), select-own RLS
-- (invisible to the partner, so reach-notify may revoke a dead row in place),
-- and three SECURITY DEFINER writers that derive the account from auth.uid().
-- reach-notify addresses the union of an account's live rows and its
-- profiles.fcm_token, deduplicated - build 73 never calls these functions and
-- is reached exactly as before through the profiles leg.
--
-- The claim invariant of 20260601005300 (a token belongs to one account,
-- newest wins) is kept here: register_push_token revokes every live row under
-- a DIFFERENT account that carries the same token or the same install, and
-- the partial unique index makes the other state unrepresentable. Without it
-- a handset signed out offline and signed into another account would keep a
-- live row for the first account, and the union would push that couple's
-- Reach and calls to whoever holds the phone now.
--
-- The mirror: register_push_token also writes profiles.fcm_token (firing
-- profiles_claim_fcm_token exactly as a client write does), so the column
-- keeps its meaning for every reader that predates this file.
-- fcm_token_updated_at moves only when the token actually changes - it is a
-- foreground timestamp a build-73 partner can read.
--
-- Dead tokens: reach-notify sets revoked_reason = 'unregistered' on the row
-- FCM refused. register_push_token answers {"dead": true} when the caller
-- re-registers that same token from that same install; the client then
-- deletes its Firebase instance token and mints a fresh one. That is the
-- self-heal the profiles slot never had.
--
-- Additive: one table, two indexes, three functions. Re-runnable: if not
-- exists / create or replace / drop policy if exists; grants are idempotent;
-- the assertions pass again.
--
-- ROLLBACK (paste first if needed; profiles.fcm_token is untouched by it -
-- whatever the last registration mirrored there is a valid token for that
-- account):
--   drop function if exists public.revoke_other_push_tokens(text);
--   drop function if exists public.revoke_push_token(text);
--   drop function if exists public.register_push_token(text, text, text);
--   drop table if exists public.push_tokens;

-- Applied via the Supabase MCP (staging 2026-09-06, production 2026-09-06); production ledger version 20260906121544
-- (apply_migration stamps its own version - the repo prefix is the replay order).

create table if not exists public.push_tokens (
  user_id        uuid        not null references auth.users(id) on delete cascade,
  device_id      text        not null,
  token          text        not null,
  platform       text        not null default 'android',
  updated_at     timestamptz not null default now(),
  revoked_at     timestamptz,
  revoked_reason text,
  primary key (user_id, device_id),
  constraint push_tokens_device_id_size
    check (char_length(device_id) between 8 and 64),
  constraint push_tokens_token_size
    check (char_length(token) between 32 and 4096),
  constraint push_tokens_platform_kind
    check (platform in ('android', 'ios'))
);

-- One LIVE row per token across every account (the 005300 invariant).
create unique index if not exists push_tokens_live_token_uidx
  on public.push_tokens (token) where revoked_at is null;

create index if not exists push_tokens_user_live_idx
  on public.push_tokens (user_id) where revoked_at is null;

alter table public.push_tokens enable row level security;

revoke all on public.push_tokens from anon, authenticated;
grant select on public.push_tokens to authenticated;

drop policy if exists push_tokens_select_own on public.push_tokens;
create policy push_tokens_select_own on public.push_tokens
  for select using (user_id = (select auth.uid()));

comment on table public.push_tokens is
  'One FCM registration per (account, install). Written only by '
  'register_push_token / revoke_push_token / revoke_other_push_tokens '
  '(auth.uid()-bound) and by reach-notify (service role) when FCM reports a '
  'token unregistered. reach-notify addresses the union of an account''s '
  'live rows and profiles.fcm_token.';

create or replace function public.register_push_token(
  p_token text,
  p_device_id text,
  p_platform text default 'android'
)
returns jsonb language plpgsql security definer set search_path = public as $fn$
declare
  v_uid  uuid := auth.uid();
  v_dead boolean;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  if p_token is null or char_length(p_token) < 32 then
    raise exception 'bad_token';
  end if;
  if p_device_id is null or char_length(p_device_id) < 8 then
    raise exception 'bad_device';
  end if;

  -- The 005300 claim, for this ledger: a token or an install belongs to one
  -- account - the one registering now.
  update public.push_tokens
     set revoked_at = now(), revoked_reason = 'claimed'
   where user_id <> v_uid and revoked_at is null
     and (token = p_token or device_id = p_device_id);

  -- The same account re-registering a token it already holds under another
  -- install id (app data cleared, token kept): the older row yields.
  update public.push_tokens
     set revoked_at = now(), revoked_reason = 'superseded'
   where user_id = v_uid and device_id <> p_device_id
     and token = p_token and revoked_at is null;

  -- Re-registering the very token FCM already refused from this install is the
  -- one case the handset cannot see for itself. The row stays revoked so
  -- reach-notify does not retry it; the answer sends the client for a fresh one.
  select revoked_reason = 'unregistered' and token = p_token
    into v_dead
    from public.push_tokens
   where user_id = v_uid and device_id = p_device_id;
  if coalesce(v_dead, false) then
    update public.push_tokens set updated_at = now()
     where user_id = v_uid and device_id = p_device_id;
    return jsonb_build_object('dead', true);
  end if;

  insert into public.push_tokens (user_id, device_id, token, platform)
  values (v_uid, p_device_id, p_token, coalesce(p_platform, 'android'))
  on conflict (user_id, device_id) do update
    set token = excluded.token,
        platform = excluded.platform,
        updated_at = now(),
        revoked_at = null,
        revoked_reason = null;

  update public.profiles
     set fcm_token = p_token,
         fcm_token_updated_at = case when fcm_token is distinct from p_token
                                     then now() else fcm_token_updated_at end
   where id = v_uid;

  return jsonb_build_object('dead', false);
end $fn$;

create or replace function public.revoke_push_token(p_device_id text)
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_uid   uuid := auth.uid();
  v_token text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select token into v_token from public.push_tokens
   where user_id = v_uid and device_id = p_device_id;
  update public.push_tokens
     set revoked_at = now(), revoked_reason = 'signed_out'
   where user_id = v_uid and device_id = p_device_id and revoked_at is null;
  -- The profiles leg goes quiet too when it names this very install; another
  -- install's token stays where it is.
  if v_token is not null then
    update public.profiles
       set fcm_token = null, fcm_token_updated_at = null
     where id = v_uid and fcm_token = v_token;
  end if;
end $fn$;

create or replace function public.revoke_other_push_tokens(p_keep_device_id text)
returns integer language plpgsql security definer set search_path = public as $fn$
declare
  v_uid  uuid := auth.uid();
  v_n    integer;
  v_keep text;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  update public.push_tokens
     set revoked_at = now(), revoked_reason = 'signed_out_elsewhere'
   where user_id = v_uid and device_id <> p_keep_device_id and revoked_at is null;
  get diagnostics v_n = row_count;
  -- The profiles leg is the only one build 73 and the legacy send path read:
  -- it must name the handset that stays, never one just revoked.
  select token into v_keep from public.push_tokens
   where user_id = v_uid and device_id = p_keep_device_id and revoked_at is null;
  update public.profiles
     set fcm_token = v_keep,
         fcm_token_updated_at = case when v_keep is null then null else now() end
   where id = v_uid and fcm_token is distinct from v_keep;
  return v_n;
end $fn$;

do $grants$ declare f text; begin
  foreach f in array array[
    'register_push_token(text,text,text)',
    'revoke_push_token(text)',
    'revoke_other_push_tokens(text)'
  ] loop
    execute format('revoke all on function public.%s from public, anon;', f);
    execute format('grant execute on function public.%s to authenticated;', f);
  end loop;
end $grants$;

do $do$
begin
  if has_table_privilege('authenticated', 'public.push_tokens', 'INSERT')
     or has_table_privilege('authenticated', 'public.push_tokens', 'UPDATE')
     or has_table_privilege('authenticated', 'public.push_tokens', 'DELETE') then
    raise exception 'authenticated can write push_tokens directly';
  end if;
  if not has_table_privilege('authenticated', 'public.push_tokens', 'SELECT') then
    raise exception 'authenticated cannot read its own push_tokens rows';
  end if;
  if has_table_privilege('anon', 'public.push_tokens', 'SELECT') then
    raise exception 'anon can read push_tokens';
  end if;
  if not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'push_tokens'
      and policyname = 'push_tokens_select_own'
  ) then
    raise exception 'push_tokens_select_own is missing';
  end if;
  if not exists (
    select 1 from pg_indexes
    where schemaname = 'public' and indexname = 'push_tokens_live_token_uidx'
  ) then
    raise exception 'push_tokens_live_token_uidx did not land';
  end if;
  if not has_function_privilege('authenticated', 'public.register_push_token(text,text,text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.revoke_push_token(text)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.revoke_other_push_tokens(text)', 'EXECUTE') then
    raise exception 'authenticated cannot execute the push token functions';
  end if;
  if has_function_privilege('anon', 'public.register_push_token(text,text,text)', 'EXECUTE') then
    raise exception 'anon can execute register_push_token';
  end if;
end $do$;
