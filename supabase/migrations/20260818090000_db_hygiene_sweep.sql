-- Four small debts from the 2026-08-17 market audit (§41/§43), none of which
-- deserved its own file and all of which get worse with users:
--
-- 1. cron.job_run_details had no retention while deliver-rituals writes a row
--    every minute — ~500k rows/year of audit nobody reads, on a 500 MB cap.
-- 2. tos_acceptances policies re-evaluated auth.uid() per row (advisor
--    auth_rls_initplan), and that table is read at every app start by every
--    user — the one initplan hit that actually scales with the user count.
-- 3. storage_reap is drained ORDER BY queued_at LIMIT 2000 (reap-storage
--    edge fn) with no index on queued_at.
-- 4. delete_my_account swallowed reap-queue failures whole (`exception when
--    others then null`, twice). Deletion must never be blocked by a storage
--    problem — that reasoning stands — but a swallowed failure left no trace
--    that a user's media was silently NOT queued for erasure. A warning keeps
--    deletion unblockable and puts the failure in the database log.
--
-- Second run: no-op throughout (unschedule-if-exists + schedule, drop policy
-- if exists + create, create index if not exists, create or replace).
--
-- ── ROLLBACK ───────────────────────────────────────────────────────────────
--   select cron.unschedule('prune-cron-run-details');
--   drop index if exists public.storage_reap_queued_at_idx;
--   -- policies: re-run 20260816120000's originals (bare auth.uid());
--   -- delete_my_account: re-run 20260817090000's body (the two handlers
--   --   back to `exception when others then null`).
-- ───────────────────────────────────────────────────────────────────────────

-- 1. Retention for the cron audit table. 7 days is enough to debug a missed
-- nightly run and irrelevant to quota; the purge job's own rows fall under
-- the same knife.
do $do$ begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'prune-cron-run-details')
      then perform cron.unschedule('prune-cron-run-details'); end if;
    perform cron.schedule('prune-cron-run-details', '41 4 * * *',
      $j$delete from cron.job_run_details where end_time < now() - interval '7 days';$j$);
  else
    raise warning 'pg_cron not installed - prune-cron-run-details not scheduled';
  end if;
end $do$;

-- 2. InitPlan form: (select auth.uid()) is evaluated once per statement
-- instead of once per row. Same predicate, same rows, same grants.
drop policy if exists "tos_acceptances_select_own" on public.tos_acceptances;
create policy "tos_acceptances_select_own" on public.tos_acceptances
  for select using (user_id = (select auth.uid()));

drop policy if exists "tos_acceptances_insert_own" on public.tos_acceptances;
create policy "tos_acceptances_insert_own" on public.tos_acceptances
  for insert with check (user_id = (select auth.uid()));

-- 3. The drain's read path.
create index if not exists storage_reap_queued_at_idx
  on public.storage_reap (queued_at);

-- 4. Same body as 20260817090000, with the two silent handlers made loud.
create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path = public as $fn$
declare
  v_uid    uuid := auth.uid();
  v_couple uuid;
  v_others int;
begin
  if v_uid is null then raise exception 'not_authenticated'; end if;
  select couple_id into v_couple from public.profiles where id = v_uid;

  if v_couple is not null then
    select count(*) into v_others
      from public.profiles where couple_id = v_couple and id <> v_uid;

    if v_others = 0 then
      begin
        insert into public.storage_reap (bucket_id, name)
        select o.bucket_id, o.name
          from storage.objects o
          join public.messages m on m.couple_id = v_couple
         where (o.bucket_id = 'couple_media'
                  and o.name in (m.image_path, m.voice_path))
            or (o.bucket_id = 'couple_intimate' and o.name = m.video_path)
            or (o.bucket_id = 'couple_files'    and o.name = m.file_path)
        on conflict do nothing;

        insert into public.storage_reap (bucket_id, name)
        select o.bucket_id, o.name
          from storage.objects o
         where o.bucket_id in ('couple_media', 'couple_intimate',
                               'capsule-media', 'couple_files')
           and (storage.foldername(o.name))[1] = v_couple::text
        on conflict do nothing;
      exception when others then
        -- A storage problem must never be the reason an account cannot be
        -- deleted — but it must also never vanish: this warning is the only
        -- record that a couple's media was NOT queued for erasure.
        raise warning 'delete_my_account: couple media reap-queue failed for %: %',
          v_couple, sqlerrm;
      end;
    end if;

    update public.profiles set couple_id = null where id = v_uid;
    if v_others = 0 then
      delete from public.messages where couple_id = v_couple;
      delete from public.couples  where id = v_couple;
    end if;
  end if;

  -- The private vault. OUTSIDE the couple block and outside `v_others = 0`,
  -- because it is this user's alone: a partner staying behind has no claim on
  -- it, and someone who never paired at all still has one to clear.
  begin
    insert into public.storage_reap (bucket_id, name)
    select o.bucket_id, o.name
      from storage.objects o
     where o.bucket_id = 'personal_vault'
       and (storage.foldername(o.name))[1] = v_uid::text
    on conflict do nothing;
  exception when others then
    raise warning 'delete_my_account: personal vault reap-queue failed for %: %',
      v_uid, sqlerrm;
  end;

  delete from auth.users where id = v_uid;
end $fn$;
