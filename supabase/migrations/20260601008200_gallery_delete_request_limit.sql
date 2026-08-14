-- A refusal keeps the picture. Without a cap that is true of any single round
-- and false over a week, because nothing stopped the same photograph being put
-- up for deletion again every evening — which turns "your partner has to agree"
-- into "your partner has to keep saying no".
--
-- Three, not one: one refusal ending it forever makes a mis-tap permanent.
-- Three leaves room to genuinely change your mind and still ends the argument.
alter table public.gallery_items
  add column if not exists delete_refused_count int not null default 0;

create or replace function public.gallery_request_delete(p_ids uuid[])
returns int language plpgsql security definer set search_path = public as $fn$
declare n int;
begin
  update public.gallery_items
     set delete_requested = true,
         delete_requested_by = auth.uid(),
         delete_requested_at = now()
   where id = any(p_ids)
     and couple_id = (select public.current_user_couple_id())
     and not deleted
     and not delete_requested
     and delete_refused_count < 3;
  get diagnostics n = row_count;
  return n;
end $fn$;

-- Withdrawing your OWN request is a change of mind, not a refusal, and must not
-- burn one of the three. That is the `is distinct from auth.uid()` below.
create or replace function public.gallery_cancel_delete(p_ids uuid[])
returns int language plpgsql security definer set search_path = public as $fn$
declare n int;
begin
  update public.gallery_items
     set delete_requested = false,
         delete_refused_count = delete_refused_count
           + case when delete_requested_by is distinct from auth.uid() then 1 else 0 end,
         delete_requested_by = null,
         delete_requested_at = null
   where id = any(p_ids)
     and couple_id = (select public.current_user_couple_id())
     and delete_requested and not deleted;
  get diagnostics n = row_count;
  return n;
end $fn$;

revoke all on function public.gallery_request_delete(uuid[]) from public, anon;
revoke all on function public.gallery_cancel_delete(uuid[]) from public, anon;
grant execute on function public.gallery_request_delete(uuid[]) to authenticated;
grant execute on function public.gallery_cancel_delete(uuid[]) to authenticated;
