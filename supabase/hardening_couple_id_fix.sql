-- ───────────────────────────────────────────────────────────────────────────
-- Miles — actually close the couple_id takeover. Idempotent; no data deleted.
--
-- hardening_2026_08.sql tried to close this and BOTH of its protections were
-- silent no-ops, so the hole stayed fully open even though the file ran:
--
--   1. `revoke update (couple_id) on public.profiles from authenticated`
--      does nothing when the role holds TABLE-level UPDATE, which Supabase
--      grants by default. Postgres does not subtract a column revoke from a
--      table grant — has_column_privilege still returns true. The only way to
--      restrict by column is to drop the table-level grant and re-grant the
--      columns you DO want writable.
--
--   2. The guard trigger was declared `security definer`, so `current_user`
--      inside it evaluates to the function owner and never to 'authenticated'.
--      The raise could not fire for anyone, ever.
--
-- The attack this closes: an attacker signs up, then sends one request —
--   PATCH /rest/v1/profiles?id=eq.<their-uid>  {"couple_id":"<victim-couple>"}
-- — and every couple-scoped policy in the schema then treats them as a member.
-- Chat, vault, body-map pins, presence GPS, capsule media. Couple UUIDs are
-- not secret: they are the first path segment of every public media URL.
-- ───────────────────────────────────────────────────────────────────────────

-- ── 1. Column-level write control, done the way Postgres actually works ────
-- Built from the catalog rather than a hard-coded list, so a column added
-- later stays writable instead of silently becoming read-only.
do $$
declare
  cols text;
begin
  select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
    into cols
    from information_schema.columns
   where table_schema = 'public'
     and table_name   = 'profiles'
     and column_name <> 'couple_id';

  -- Drop the blanket grant first; a column grant cannot narrow it.
  execute 'revoke update on public.profiles from authenticated';
  execute 'revoke update on public.profiles from anon';
  execute format('grant update (%s) on public.profiles to authenticated', cols);
end $$;

-- ── 2. A guard that can actually fire ─────────────────────────────────────
-- SECURITY INVOKER on purpose. The trigger then runs as whoever is writing:
-- 'authenticated' for a direct PostgREST PATCH (blocked), and the table owner
-- when the write comes from inside a SECURITY DEFINER RPC such as
-- create_couple / redeem_pairing_invite / leave_couple / delete_my_account
-- (allowed), because SECURITY DEFINER switches current_user for its duration.
create or replace function public.guard_couple_id()
returns trigger language plpgsql as $$
begin
  if new.couple_id is distinct from old.couple_id
     and current_user in ('authenticated', 'anon') then
    raise exception 'couple_id is not client-writable';
  end if;
  return new;
end; $$;

drop trigger if exists trg_guard_couple_id on public.profiles;
create trigger trg_guard_couple_id
  before update of couple_id on public.profiles
  for each row execute function public.guard_couple_id();

-- ── 4. Same defect, same class: capsules.unlocked_at and vault_pin.pin_hash ─
-- Both were also written as bare column-level revokes against a table-level
-- grant, so a sealed capsule could still unseal itself and the 4-digit PIN
-- hash (10,000 candidates — an instant offline break) was still SELECTable.
do $$
declare cols text;
begin
  if to_regclass('public.capsules') is not null then
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
      into cols
      from information_schema.columns
     where table_schema = 'public' and table_name = 'capsules'
       and column_name <> 'unlocked_at';
    execute 'revoke update on public.capsules from authenticated, anon';
    execute format('grant update (%s) on public.capsules to authenticated', cols);
  end if;

  if to_regclass('public.vault_pin') is not null then
    select string_agg(quote_ident(column_name), ', ' order by ordinal_position)
      into cols
      from information_schema.columns
     where table_schema = 'public' and table_name = 'vault_pin'
       and column_name <> 'pin_hash';
    execute 'revoke select on public.vault_pin from authenticated, anon';
    execute format('grant select (%s) on public.vault_pin to authenticated', cols);
  end if;
end $$;

-- ── 3. Prove it ───────────────────────────────────────────────────────────
-- Both must report false / OK. has_column_privilege is the honest check:
-- it accounts for table-level grants, which is exactly what the first attempt
-- got wrong.
select 'authenticated can write couple_id' as check,
       has_column_privilege('authenticated', 'public.profiles', 'couple_id', 'UPDATE')
         as still_writable
union all
select 'authenticated can write display_name (must stay true)',
       has_column_privilege('authenticated', 'public.profiles', 'display_name', 'UPDATE')
union all
select 'authenticated can write capsules.unlocked_at',
       case when to_regclass('public.capsules') is null then false
            else has_column_privilege('authenticated', 'public.capsules', 'unlocked_at', 'UPDATE') end
union all
select 'authenticated can read vault_pin.pin_hash',
       case when to_regclass('public.vault_pin') is null then false
            else has_column_privilege('authenticated', 'public.vault_pin', 'pin_hash', 'SELECT') end;
