-- ───────────────────────────────────────────────────────────────────────────
-- Miles — what a breakup leaves behind.
--
-- FIRST, A CORRECTION, because the wrong version of this got said twice during
-- the audit: an ex-partner does NOT keep a key. leave_couple() nulls both
-- profiles' couple_id, and every check in the system — table RLS, storage RLS,
-- the realtime topic policy — resolves against the caller's CURRENT couple_id.
-- Remembering the UUID buys nothing. Access is correct.
--
-- What is not correct is that nothing is ever removed. The messages stay. The
-- intimate photographs stay. The presence rows stay. Unreadable, because nobody
-- holds that couple_id any more, and permanent.
--
-- At two users that is a rounding error. At thousands it becomes the largest
-- single category of stored data, growing with every breakup, and it is
-- intimate content belonging to a relationship that ended and to people who
-- would reasonably assume leaving meant leaving.
--
-- Thirty days: long enough that a couple who split on Tuesday and reconciled on
-- Friday lose nothing, short enough that "we deleted it" is true. Re-pairing
-- clears the clock, so reconciliation inside the window costs nothing.
-- ───────────────────────────────────────────────────────────────────────────

alter table public.couples add column if not exists dissolved_at timestamptz;

create or replace function public.leave_couple()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_uid uuid := auth.uid(); v_couple uuid;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;
  if v_couple is null then return; end if;
  update public.profiles set couple_id = null where couple_id = v_couple;
  update public.couples
     set active = false,
         dissolved_at = coalesce(dissolved_at, now())
   where id = v_couple;
end $fn$;

revoke execute on function public.leave_couple() from public, anon;
grant execute on function public.leave_couple() to authenticated;

create or replace function public.clear_dissolved_on_join()
returns trigger language plpgsql security definer set search_path = public as $fn$
begin
  if new.couple_id is not null and new.couple_id is distinct from old.couple_id then
    update public.couples
       set active = true, dissolved_at = null
     where id = new.couple_id and dissolved_at is not null;
  end if;
  return new;
end $fn$;

drop trigger if exists profiles_clear_dissolved on public.profiles;
create trigger profiles_clear_dissolved
  after update of couple_id on public.profiles
  for each row execute function public.clear_dissolved_on_join();

create or replace function public.prune_dissolved_couples()
returns void language plpgsql security definer set search_path = public as $fn$
declare v_ids uuid[];
begin
  select coalesce(array_agg(id), '{}') into v_ids
    from public.couples
   where dissolved_at is not null
     and dissolved_at < now() - interval '30 days'
     and not exists (select 1 from public.profiles p where p.couple_id = couples.id);

  if array_length(v_ids, 1) is null then return; end if;

  -- Media first: it is the bulk, and it is the intimate part.
  delete from storage.objects
   where bucket_id in ('couple_media','couple_intimate','capsule-media')
     and (storage.foldername(name))[1] = any (select unnest(v_ids)::text);

  -- Then the couple. Every couple-scoped table cascades from here — the same
  -- foreign keys account deletion depends on — so this needs no table list that
  -- would rot the next time a feature adds one.
  delete from public.couples where id = any (v_ids);
end $fn$;

revoke execute on function public.prune_dissolved_couples() from public, anon, authenticated;

-- Couples dissolved before this migration have no timestamp and would never be
-- collected. Start their clock now rather than leaving them permanent.
update public.couples c
   set dissolved_at = now()
 where not c.active and c.dissolved_at is null
   and not exists (select 1 from public.profiles p where p.couple_id = c.id);

do $do$
begin
  if exists (select 1 from pg_extension where extname='pg_cron') then
    if exists (select 1 from cron.job where jobname='prune-dissolved-couples') then
      perform cron.unschedule('prune-dissolved-couples');
    end if;
    perform cron.schedule('prune-dissolved-couples', '7 5 * * *',
      'select public.prune_dissolved_couples()');
  end if;
end $do$;
