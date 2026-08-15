-- The couple row holds four things a member must never write directly.
--
-- couples_update_member says only "the row must be your own couple", and
-- authenticated held a TABLE-level UPDATE, so every column was in reach of a
-- PostgREST PATCH: dissolved_at (un-delete the couple, cancel the 30-day
-- purge), active, stripe_customer_id (point billing at somebody else's
-- customer), invite_code. The policy was never the wrong shape; the grant was.
--
-- Lifecycle belongs to leave_couple/redeem_pairing_invite and billing belongs
-- to the server. Both are SECURITY DEFINER owned by postgres, so they execute
-- with the owner's rights and are untouched by this.
--
-- Table-level revoke BEFORE the column grant; a column-level revoke alone is a
-- silent no-op against a table-level grant.
revoke update on public.couples from authenticated;
grant update (name, anniversary_date, modest_mode, primary_tz)
  on public.couples to authenticated;

do $do$ begin
  if exists (select 1 from information_schema.table_privileges
              where grantee = 'authenticated' and table_schema = 'public'
                and table_name = 'couples' and privilege_type = 'UPDATE') then
    raise exception 'couples must be column-grant update only';
  end if;
end $do$;
