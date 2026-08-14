-- 006900 revoked DELETE from six tables that were always meant to allow it.
--
-- Its predicate was:
--     left join pg_policy p on p.polrelid = c.oid and p.polcmd = 'd'
--
-- `polcmd = 'd'` matches only a policy written `FOR DELETE`. A policy written
-- `FOR ALL` has `polcmd = '*'` and covers DELETE too — so every table whose
-- delete permission came from a FOR ALL policy looked, to that query, exactly
-- like a table with no delete policy at all. Six were stripped:
--
--     personal_vault_items   pvi_owner_only          FOR ALL
--     vault_pin              vault_pin_self          FOR ALL
--     cycle_events           cycle_events_owner      FOR ALL
--     cycle_logs             cycle_logs_owner        FOR ALL
--     cycle_settings         cycle_settings_owner    FOR ALL
--     call_signals           call_signals_rw         FOR ALL
--
-- love_reasons and intimacy_signals survived only because they happen to be
-- written FOR DELETE. That is the whole difference.
--
-- One of the six is a LIVE BREAKAGE: vault_repository.dart:98 calls
-- `.from('personal_vault_items').delete().eq('id', id)`, so "delete from vault"
-- has been failing in production since 006900 shipped.
--
-- 006900's own commit claimed "Verified after: 0 tables remain in that state."
-- It re-ran the same wrong predicate, so it confirmed nothing — a checkable
-- claim checked with the buggy check.

-- ── Restore the five that legitimately delete ──────────────────────────────
-- vault_pin is deliberately NOT in this list; see below.
grant delete on public.personal_vault_items to authenticated;
grant delete on public.cycle_events   to authenticated;
grant delete on public.cycle_logs     to authenticated;
grant delete on public.cycle_settings to authenticated;
grant delete on public.call_signals   to authenticated;

-- ── vault_pin: the opposite problem ────────────────────────────────────────
-- verify_vault_pin implements a real lockout — bcrypt, five strikes, fifteen
-- minutes:
--
--   locked_until = case when failed_attempts + 1 >= 5
--                       then now() + interval '15 minutes' else null end
--
-- and it is worthless while the person being locked out can write the table
-- that counts their failures. `vault_pin_self` is FOR ALL on
-- `user_id = auth.uid()`, so PATCH /rest/v1/vault_pin with
-- {"failed_attempts":0,"locked_until":null} resets the counter, and a 4-digit
-- PIN is 10,000 candidates with no limiter left.
--
-- 004900 got this exact reasoning right for pairing and wrote it down — "a user
-- who can read or clear their own failure count has no limiter" — and
-- pairing_attempts has RLS on, no policy, and no grants. That reasoning simply
-- was never carried to vault_pin.
--
-- All three entry points are SECURITY DEFINER and run as owner, so revoking
-- direct DML costs the client nothing: has_vault_pin(), set_vault_pin(p_pin),
-- verify_vault_pin(p_pin). SELECT was already withheld, which is why the bcrypt
-- hash was never readable.
revoke insert, update, delete on public.vault_pin from authenticated, anon;

do $do$
declare bad text;
begin
  select string_agg(c.relname, ', ') into bad
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity
     and c.relname <> 'vault_pin'
     and exists (select 1 from pg_policy p
                  where p.polrelid = c.oid and p.polcmd in ('d','*'))
     and not has_table_privilege('authenticated', c.oid, 'DELETE');
  if bad is not null then
    raise exception 'still cannot delete where a policy allows it: %', bad;
  end if;

  if has_table_privilege('authenticated', 'public.vault_pin', 'UPDATE') then
    raise exception 'vault_pin is still self-writable; the lockout is bypassable';
  end if;
end $do$;
