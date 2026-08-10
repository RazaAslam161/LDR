-- ───────────────────────────────────────────────────────────────────────────
-- Miles — call_invites: four overlapping policies, one of which was a hole.
--
-- The table carried a FOR ALL policy in the current style plus three older ones
-- written against an inline profiles subquery, left behind by an earlier
-- rewrite. The advisor flags that as a performance problem, which it is — every
-- permissive policy is evaluated on every row.
--
-- The security consequence is the reason this is its own migration. PERMISSIVE
-- POLICIES ARE OR-ED. The strict one,
--
--     caller_id = auth.uid() AND couple_id = <mine>
--
-- was therefore SUPERSEDED by the loose one,
--
--     couple_id = <mine>
--
-- so the caller_id check never applied. A signed-in user could insert a call
-- invite attributed to their PARTNER — and since an insert here is what fires
-- the FCM ring, that is a call that appears to come from someone it did not.
-- Adding a stricter policy alongside a looser one does not narrow anything; it
-- widens. That is the general lesson, not a detail of this table.
--
-- Now one policy per command, so nothing ORs with anything.
--
-- BEHAVIOUR CHANGE: an insert must now have caller_id = the signed-in user.
-- call_controller._insertInvite already sends session.profile.id, which is
-- auth.uid(). If that ever stops being true the insert fails, and the
-- diag_events row `call.invite_failed` is where it will say so.
-- ───────────────────────────────────────────────────────────────────────────

drop policy if exists "call_invites caller insert" on public.call_invites;
drop policy if exists "call_invites couple read"   on public.call_invites;
drop policy if exists "call_invites couple update" on public.call_invites;
drop policy if exists call_invites_couple          on public.call_invites;

create policy call_invites_select on public.call_invites
  for select using (couple_id = (select public.current_user_couple_id()));

create policy call_invites_insert on public.call_invites
  for insert with check (
    caller_id = (select auth.uid())
    and couple_id = (select public.current_user_couple_id())
  );

create policy call_invites_update on public.call_invites
  for update using (couple_id = (select public.current_user_couple_id()))
         with check (couple_id = (select public.current_user_couple_id()));

create policy call_invites_delete on public.call_invites
  for delete using (couple_id = (select public.current_user_couple_id()));
