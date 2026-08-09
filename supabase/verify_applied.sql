-- ───────────────────────────────────────────────────────────────────────────
-- Miles — did every migration actually land? Read-only; changes nothing.
--
-- Run this in the SQL editor. Every row should read OK. Anything that says
-- MISSING names the file to run.
-- ───────────────────────────────────────────────────────────────────────────
select 'couple_id not client-writable' as check,
       case when has_column_privilege('authenticated', 'public.profiles', 'couple_id', 'UPDATE')
            then 'MISSING -> hardening_2026_08.sql' else 'OK' end as status
union all
select 'join_couple_by_code removed',
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname = 'join_couple_by_code')
            then 'MISSING -> hardening_2026_08.sql' else 'OK' end
union all
select 'delete_my_account exists',
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname = 'delete_my_account')
            then 'OK' else 'MISSING -> account_deletion.sql' end
union all
select 'messages.seq exists',
       case when exists (select 1 from information_schema.columns
                          where table_schema = 'public' and table_name = 'messages'
                            and column_name = 'seq')
            then 'OK' else 'MISSING -> receipts_v2.sql' end
union all
select 'chat_receipts table exists',
       case when to_regclass('public.chat_receipts') is not null
            then 'OK' else 'MISSING -> receipts_v2.sql' end
union all
select 'ack_read / ack_delivered exist',
       case when (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                   where n.nspname = 'public' and p.proname in ('ack_read', 'ack_delivered')) = 2
            then 'OK' else 'MISSING -> receipts_v2.sql' end
union all
select 'chat_receipts is realtime',
       case when exists (select 1 from pg_publication_tables
                          where pubname = 'supabase_realtime' and schemaname = 'public'
                            and tablename = 'chat_receipts')
            then 'OK' else 'MISSING -> receipts_v2.sql (publication step)' end
union all
select 'message push trigger exists',
       case when exists (select 1 from pg_trigger
                          where tgname = 'message_notify_on_insert' and not tgisinternal)
            then 'OK' else 'MISSING -> message_push.sql' end
union all
select 'media cleanup on delete',
       case when exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                          where n.nspname = 'public' and p.proname = 'delete_message_for_everyone'
                            and pg_get_functiondef(p.oid) ilike '%storage.objects%')
            then 'OK' else 'MISSING -> chat_media_cleanup.sql' end
union all
-- Every existing message needs a seq or the receipt comparison has nothing to
-- compare: a NULL seq renders as "sent" forever.
select 'no messages left without a seq',
       case when to_regclass('public.messages') is null then 'n/a'
            when (select count(*) from public.messages where seq is null) = 0
            then 'OK' else 'MISSING -> re-run receipts_v2.sql backfill' end;
