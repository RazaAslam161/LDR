-- ───────────────────────────────────────────────────────────────────────────
-- Miles — what is actually in presence right now? Read-only; changes nothing.
--
-- Run this in the SQL editor while BOTH of you have the app open.
-- Three questions, answered from live data rather than from reading code:
--   1. does the schema match what the client writes?
--   2. does each partner actually HAVE a presence row?
--   3. how far wrong is each device's clock?
--
-- (3) matters because "is my partner online" is computed by comparing a
-- timestamp stamped by THEIR phone against THIS phone's clock. Two phones that
-- disagree produce opposite answers in each direction — which is exactly what
-- an asymmetric "she can't see me but I can see her" looks like.
-- ───────────────────────────────────────────────────────────────────────────

-- ── 1. Schema vs what the client sends ────────────────────────────────────
-- PostgREST rejects the ENTIRE upsert with PGRST204 if ANY named column is
-- missing — so one absent column silently kills online status, typing, mood,
-- location and current_screen together. The client's catch is bare, so there
-- is no error anywhere: presence simply never updates.
select 'SCHEMA' as section,
       c.col as client_writes_this_column,
       case when exists (
              select 1 from information_schema.columns
               where table_schema = 'public' and table_name = 'presence'
                 and column_name = c.col)
            then 'ok'
            else '*** MISSING -> every presence write fails (PGRST204) ***'
       end as status
  from (values
    ('user_id'), ('couple_id'), ('is_online'), ('last_seen'), ('is_typing'),
    ('typing_in_chat'), ('current_mood'), ('mood_color'), ('mood_updated_at'),
    ('latitude'), ('longitude'), ('location_label'), ('location_sharing_mode'),
    ('location_accuracy'), ('location_updated_at'), ('current_screen'),
    ('body_photo_path'), ('avatar_emoji'), ('checkin_photo_url'),
    ('checkin_photo_at'), ('updated_at'), ('app_last_active_at'),
    ('chat_last_read')
  ) as c(col)
 order by status desc, client_writes_this_column;

-- ── 2. Who has a row, and what does it say? ───────────────────────────────
-- A partner with NO row is invisible no matter how healthy the client is, and
-- produces precisely the reported asymmetry: he sees her row, she has none of
-- his to read.
select 'ROWS' as section,
       p.display_name,
       pr.user_id is not null            as has_presence_row,
       pr.is_online,
       pr.current_screen,
       pr.couple_id = p.couple_id        as couple_id_matches_profile
  from public.profiles p
  left join public.presence pr on pr.user_id = p.id
 where p.couple_id is not null
 order by p.display_name;

-- ── 3. Clock skew, measured against the server ────────────────────────────
-- app_last_active_at is stamped by the DEVICE. now() is the SERVER. If a
-- device's clock is behind, skew_seconds is large and positive and that
-- person reads as permanently offline to their partner. If it is ahead, skew
-- goes NEGATIVE and they read as permanently online even with the phone off.
-- Anything beyond roughly +/-45s breaks the online indicator outright.
select 'CLOCK SKEW' as section,
       p.display_name,
       pr.app_last_active_at,
       now() as server_now,
       round(extract(epoch from (now() - pr.app_last_active_at)))::int
         as seconds_behind_server,
       case
         when pr.app_last_active_at is null then 'never stamped'
         when abs(extract(epoch from (now() - pr.app_last_active_at))) > 45
           then '*** outside the 45s window -> status will be wrong ***'
         else 'within window'
       end as verdict
  from public.profiles p
  join public.presence pr on pr.user_id = p.id
 where p.couple_id is not null
 order by p.display_name;
