-- ───────────────────────────────────────────────────────────────────────────
-- Miles — partner rewrap: the couple's key survives one phone at a time.
--
-- The couple key is DERIVED at runtime, HKDF over X25519(mySeed, partnerPub),
-- and never stored. A reinstall mints a new seed, so the derived key changes
-- and every prior row becomes unreadable ON BOTH PHONES. The only recovery
-- today is key_escrow, sealed under a password nothing ever verified — a typo
-- at that prompt produces a row nobody alive can open, and says nothing.
--
-- This is the second door, and it needs no password: the partner's phone still
-- holds the old key, so it hands it over. What the server carries is one
-- short-lived row per attempt — a fresh PUBLIC key, a commitment to the six
-- digits the reinstalling phone shows, and, once answered, a blob sealed to
-- that public key. The server can open none of it, and cannot substitute a
-- public key of its own without the digits spoken over the call.
-- ───────────────────────────────────────────────────────────────────────────

create table if not exists public.partner_rewrap_requests (
  id             uuid primary key default gen_random_uuid(),
  couple_id      uuid not null references public.couples(id) on delete cascade,
  -- Named from_user so enforce_send_rate reads the sender unchanged.
  from_user      uuid not null references public.profiles(id) on delete cascade,
  -- X25519 public key, base64. Deliberately NOT yet in partner_keys:
  -- publishing before the old key is in hand rotates the couple key with
  -- nothing left that can open the past.
  new_public_key text not null,
  -- Argon2id(secret = the six ASCII digits, salt = the raw 32-byte public key),
  -- m=19456 KiB, t=2, p=1, 32 bytes out — the same parameters key_escrow uses.
  -- Binds the digits to the key, so a substituted key cannot pass the digits
  -- the partner types. Argon2id rather than SHA-256 because the public key sits
  -- in this row: anyone who can READ the row can exhaust all 10^6 six-digit
  -- preimages, and against SHA-256 that is microseconds. Memory-hard makes the
  -- same sweep ~6 core-days of 19 MB-hard work inside a 10-minute window. That
  -- is funded rather than free; six digits cannot be made more than that.
  code_hash      bytea not null,
  -- nonce(24) || mac(16) || ciphertext(258), sealed to new_public_key. Fixed
  -- length: a variable blob would tell the server how many times this couple
  -- has re-keyed. Null until the partner answers.
  wrapped_keys   bytea,
  wrapped_by     uuid references public.profiles(id) on delete set null,
  wrapped_at     timestamptz,
  created_at     timestamptz not null default now(),
  -- A ceremony, not a queue. Both of them are on the call or it does not happen.
  expires_at     timestamptz not null default now() + interval '10 minutes',
  constraint partner_rewrap_code_hash_len check (octet_length(code_hash) = 32),
  constraint partner_rewrap_pubkey_len    check (length(new_public_key) = 44),
  constraint partner_rewrap_blob_len      check (
    wrapped_keys is null or octet_length(wrapped_keys) = 298)
);

alter table public.partner_rewrap_requests enable row level security;

drop policy if exists partner_rewrap_member on public.partner_rewrap_requests;
create policy partner_rewrap_member on public.partner_rewrap_requests
  for select using (couple_id = (select public.current_user_couple_id()));
drop policy if exists partner_rewrap_open on public.partner_rewrap_requests;
create policy partner_rewrap_open on public.partner_rewrap_requests
  for insert with check (couple_id = (select public.current_user_couple_id())
                         and from_user = auth.uid());
-- Only the OTHER half may answer, once, before it expires. Answering your own
-- request is the whole attack: a stolen unlocked phone would otherwise seal the
-- old key to a key it just minted, with no second human anywhere in the loop.
drop policy if exists partner_rewrap_answer on public.partner_rewrap_requests;
create policy partner_rewrap_answer on public.partner_rewrap_requests
  for update using (couple_id = (select public.current_user_couple_id())
                    and from_user <> auth.uid()
                    and wrapped_keys is null
                    and expires_at > now())
          with check (couple_id = (select public.current_user_couple_id())
                      and from_user <> auth.uid()
                      and wrapped_by = auth.uid());
drop policy if exists partner_rewrap_close on public.partner_rewrap_requests;
create policy partner_rewrap_close on public.partner_rewrap_requests
  for delete using (from_user = auth.uid());

revoke all on public.partner_rewrap_requests from anon;
revoke truncate, references, trigger on public.partner_rewrap_requests from authenticated, anon;
-- Table-level revoke BEFORE the column grant; a column-level revoke alone is a
-- silent no-op.
revoke update on public.partner_rewrap_requests from authenticated;
grant select, insert, delete on public.partner_rewrap_requests to authenticated;
grant update (wrapped_keys, wrapped_by, wrapped_at)
  on public.partner_rewrap_requests to authenticated;

-- ── Rate limit ─────────────────────────────────────────────────────────────
-- 1 per 60s, 3 per hour. The gap is for a mistyped code retried immediately;
-- the window cap is the actual security argument. Six digits is 10^6, so three
-- online guesses an hour is one expected success every ~38 years — the ceiling
-- that makes a short code usable at all.
create or replace function public.send_next_allowed_at(p_table text, p_sender uuid)
returns timestamptz language plpgsql stable security definer
set search_path = public as $fn$
declare
  v_col text; v_gap interval; v_burst int; v_window interval; v_at timestamptz;
begin
  case p_table
    when 'reach_events' then
      v_col := 'from_user'; v_gap := interval '30 seconds';
      v_burst := 5;  v_window := interval '5 minutes';
    when 'care_nudges' then
      v_col := 'from_user'; v_gap := interval '30 seconds';
      v_burst := 10; v_window := interval '1 hour';
    when 'call_invites' then
      v_col := 'caller_id'; v_gap := interval '15 seconds';
      v_burst := 10; v_window := interval '10 minutes';
    when 'partner_rewrap_requests' then
      v_col := 'from_user'; v_gap := interval '60 seconds';
      v_burst := 3;  v_window := interval '1 hour';
    else raise exception 'no send rate defined for %', p_table;
  end case;
  execute format($q$
    select greatest(
      (select max(created_at) from public.%1$I where %2$I = $1) + $2,
      (select created_at from public.%1$I where %2$I = $1
        order by created_at desc offset $3 limit 1) + $4)
  $q$, p_table, v_col)
  into v_at using p_sender, v_gap, v_burst - 1, v_window;
  return v_at;
end $fn$;

revoke execute on function public.send_next_allowed_at(text, uuid)
  from public, anon, authenticated;

drop trigger if exists partner_rewrap_rate_limit on public.partner_rewrap_requests;
create trigger partner_rewrap_rate_limit before insert on public.partner_rewrap_requests
  for each row execute function public.enforce_send_rate();

create index if not exists partner_rewrap_sender_time_idx
  on public.partner_rewrap_requests (from_user, created_at desc);

do $do$ begin
  if not exists (select 1 from pg_publication_tables
                  where pubname='supabase_realtime' and schemaname='public'
                    and tablename='partner_rewrap_requests') then
    alter publication supabase_realtime add table public.partner_rewrap_requests;
  end if;
end $do$;

-- The column grant only holds if no table-level UPDATE survives beside it.
do $do$ begin
  if exists (select 1 from information_schema.table_privileges
              where grantee = 'authenticated' and table_schema = 'public'
                and table_name = 'partner_rewrap_requests'
                and privilege_type = 'UPDATE') then
    raise exception 'partner_rewrap_requests must be column-grant update only';
  end if;
end $do$;
