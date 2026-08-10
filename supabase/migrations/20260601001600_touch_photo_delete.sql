-- ───────────────────────────────────────────────────────────────────────────
-- Tethered — TOUCH body-photo delete. Run AFTER presence_and_mood.sql.
--
-- Lets either partner remove a body photo (their own OR their partner's) from
-- the Touch screen. presence RLS is self-only (presence_update_self), so a
-- couple member can't null the other's body_photo_path directly. This
-- security-definer function does it, gated on shared couple membership, and
-- best-effort deletes the stored file so it disappears for both partners.
-- ───────────────────────────────────────────────────────────────────────────
create or replace function public.clear_body_photo(p_target uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  v_couple uuid := public.current_user_couple_id();
  v_path   text;
begin
  if v_couple is null then raise exception 'no_couple'; end if;
  -- The target must belong to the caller's couple (self or partner).
  if not exists (
    select 1 from public.profiles where id = p_target and couple_id = v_couple
  ) then
    raise exception 'not_in_couple';
  end if;
  select body_photo_path into v_path from public.presence where user_id = p_target;
  update public.presence
     set body_photo_path = null, updated_at = now()
   where user_id = p_target and couple_id = v_couple;
  -- Best-effort: drop the stored object so no signed URL can be minted for it.
  if v_path is not null then
    begin
      delete from storage.objects
       where bucket_id = 'couple_intimate' and name = v_path;
    exception when others then null;
    end;
  end if;
end; $$;
revoke execute on function public.clear_body_photo(uuid) from public, anon;
grant  execute on function public.clear_body_photo(uuid) to authenticated;
