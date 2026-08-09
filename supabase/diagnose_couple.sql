-- ───────────────────────────────────────────────────────────────────────────
-- Miles — who is actually paired with whom, and is anyone reading a dead row?
-- Read-only.
--
-- The clock-skew check surfaced TWO profiles named "John", one of which has
-- never stamped app_last_active_at. If a couple is linked to the wrong one --
-- or if a couple somehow has more than two members, or a presence row whose
-- couple_id disagrees with the profile's -- then one partner reads a row that
-- never updates: permanently offline, no current screen, forever, while the
-- other side looks perfectly healthy. That is what asymmetric presence is.
-- ───────────────────────────────────────────────────────────────────────────

-- ── 1. Every couple and its members ───────────────────────────────────────
-- member_count > 2 means the 2-member cap was bypassed at some point and
-- partner lookup is now ambiguous.
select 'COUPLES' as section,
       c.id as couple_id,
       count(p.id) as member_count,
       string_agg(p.display_name || ' [' || left(p.id::text, 8) || ']', ' + '
                  order by p.created_at) as members,
       c.created_at
  from public.couples c
  left join public.profiles p on p.couple_id = c.id
 group by c.id, c.created_at
 order by member_count desc, c.created_at desc;

-- ── 2. Presence health per member ─────────────────────────────────────────
-- has_row=false or couple_id_mismatch=true means this person is invisible to
-- their partner no matter how well the client behaves.
select 'MEMBERS' as section,
       p.display_name,
       left(p.id::text, 8)        as profile_id,
       left(p.couple_id::text, 8) as couple_id,
       (pr.user_id is not null)   as has_presence_row,
       (pr.couple_id is distinct from p.couple_id) as couple_id_mismatch,
       pr.is_online,
       pr.current_screen,
       pr.app_last_active_at,
       pr.updated_at
  from public.profiles p
  left join public.presence pr on pr.user_id = p.id
 where p.couple_id is not null
 order by p.couple_id, p.created_at;

-- ── 3. Orphaned / duplicate presence rows ─────────────────────────────────
-- A presence row whose couple_id points somewhere its owner no longer belongs
-- still satisfies "presence_select_couple" for the OLD couple, so a partner
-- can be served a stranger's stale row -- or their ex-partner's.
select 'ORPHANS' as section,
       left(pr.user_id::text, 8)   as presence_user,
       left(pr.couple_id::text, 8) as presence_couple,
       left(p.couple_id::text, 8)  as profile_couple,
       p.display_name,
       pr.app_last_active_at
  from public.presence pr
  left join public.profiles p on p.id = pr.user_id
 where p.id is null
    or pr.couple_id is distinct from p.couple_id;
