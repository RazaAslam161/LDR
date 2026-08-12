-- ───────────────────────────────────────────────────────────────────────────
-- Miles — stop diagnostics from being able to take the database down.
--
-- diag_events is 37.6 MB of a 57.6 MB database: 65% of everything stored here
-- is instrumentation, and 60,645 of those rows arrived in a single day. From
-- two handsets, with diagnostics switched on by hand.
--
-- Retention was a daily DELETE by age. That is a policy, not a bound — it
-- assumes tomorrow's write volume resembles today's, and says nothing about
-- what happens between two runs of a job that fires once at 04:17. Diagnostics
-- default off, so today the fleet writes nothing; the day anyone turns them on
-- across a real number of couples, one night's traffic can pass the 500 MB
-- ceiling before the prune next wakes. Every table in the project goes
-- read-only when it does, and the first symptom is the whole app failing to
-- write.
--
-- So: keep the age policy, add an absolute bound underneath it, and make the
-- job's own health something you can query instead of something you assume.
-- ───────────────────────────────────────────────────────────────────────────

-- The age delete has never had an index — 86k rows scan fine, 5M do not. BRIN
-- rather than btree because the table is append-only and received_at rises with
-- the physical order, which is precisely the case BRIN exists for: a few kB of
-- index instead of a few hundred MB, on a table whose whole problem is size.
create index if not exists diag_events_received_at_brin
  on public.diag_events using brin (received_at);

-- Health of the maintenance jobs themselves. Without this, a prune that has
-- been failing for a week and a prune that had nothing to do look identical
-- from the outside — and the second-worst outcome after an outage is an outage
-- nobody can date.
create table if not exists public.ops_job_runs (
  jobname               text primary key,
  last_ok_at            timestamptz,
  last_error_at         timestamptz,
  last_error            text,
  consecutive_failures  integer not null default 0,
  -- What the job saw when it last ran. For a prune this is the row count it
  -- left behind: the number that says whether the bound is holding.
  last_note             text
);

alter table public.ops_job_runs enable row level security;
-- No policy. Operational state is for the service role and the dashboard, not
-- for clients; RLS with no policy is deny-all, which is the intent.

create or replace function public.ops_record_job(
  p_jobname text,
  p_note    text default null
) returns void language sql security definer set search_path = public as $fn$
  insert into public.ops_job_runs (jobname, last_ok_at, consecutive_failures, last_note)
  values (p_jobname, now(), 0, p_note)
  on conflict (jobname) do update
    set last_ok_at = now(),
        consecutive_failures = 0,
        last_note = excluded.last_note;
$fn$;
revoke execute on function public.ops_record_job(text, text) from public, anon, authenticated;

create or replace function public.prune_diag_events()
returns void language plpgsql security definer set search_path = public as $fn$
declare
  -- ~433 bytes per row including both indexes, measured against the live
  -- table. 200k rows is therefore ~87 MB: enough to hold a real incident's
  -- worth of trace, small enough that it cannot be the reason the project
  -- hits its storage ceiling.
  max_rows constant integer := 200000;
  cutoff_id bigint;
  remaining bigint;
begin
  -- The policy: a trace is read while the bug is being chased, not a week
  -- later.
  delete from public.diag_events where received_at < now() - interval '2 days';

  -- The bound. Deliberately by row count and not by pg_total_relation_size:
  -- bytes do not drop until autovacuum runs, so a size-driven loop would keep
  -- deleting against a number that cannot fall and would empty the table.
  -- Rows fall immediately.
  --
  -- Below the cap the subquery returns no row, so cutoff_id is null and
  -- `id < null` deletes nothing. The bound costs one index lookup on the
  -- common path.
  select id into cutoff_id
    from public.diag_events order by id desc offset max_rows limit 1;
  if cutoff_id is not null then
    delete from public.diag_events where id < cutoff_id;
  end if;

  select count(*) into remaining from public.diag_events;
  perform public.ops_record_job(
    'prune-diag-events',
    remaining || ' rows retained' ||
      case when cutoff_id is not null then ' (row cap enforced)' else '' end
  );
end $fn$;
revoke execute on function public.prune_diag_events() from public, anon, authenticated;

-- Hourly, not daily. The bound is only worth as much as the frequency with
-- which it is applied: once a day leaves a 24-hour window in which the table
-- grows unchecked, which is the window that was the problem. The delete is an
-- index lookup and two no-op deletes when there is nothing to do.
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    if exists (select 1 from cron.job where jobname = 'prune-diag-events') then
      perform cron.unschedule('prune-diag-events');
    end if;
    perform cron.schedule('prune-diag-events', '17 * * * *',
      'select public.prune_diag_events()'
    );
  end if;
end $do$;
