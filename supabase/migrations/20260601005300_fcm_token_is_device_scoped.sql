-- ───────────────────────────────────────────────────────────────────────────
-- Miles — one FCM token belongs to one account at a time.
--
-- THE BREACH THIS CLOSES. profiles.fcm_token is a DEVICE identity stored in a
-- PER-USER column. Sign out of account A on a handset and into account B, and
-- both rows end up holding the same token string. Production had exactly that:
--
--   select fcm_token, count(*) from profiles where fcm_token is not null
--   group by fcm_token having count(*) > 1;   -- one token, two profiles
--
-- The two rows were in DIFFERENT couples. reach-notify looks the recipient up
-- by couple_id, finds A's stale row, and pushes A's couple's private signal to
-- a handset that is now signed in as B. One couple's Reach delivered into
-- another couple's session. On two phones that is confusing; on a fleet it is
-- a cross-tenant data leak.
--
-- Clearing the token on sign-out (which the client now does on every path) is
-- necessary but NOT sufficient: it needs the app to be running, online, and
-- still authenticated. A force-stop, a wiped app, a dead network or a crash
-- during sign-out all leave the stale row behind. The invariant has to hold
-- server-side, where nothing can skip it.
--
-- WHY A TRIGGER AND NOT A BARE UNIQUE CONSTRAINT. A unique index alone gets
-- the resolution backwards: the newcomer's UPDATE would FAIL and the STALE row
-- would keep the token — the leaking row wins and the live device goes silent.
-- The newest registration must win, because it is the one that reflects who is
-- actually holding the handset. So: a trigger that takes the token off every
-- other row, with the unique index kept underneath as the backstop that turns
-- any future path we forget about into an error instead of a leak.
-- ───────────────────────────────────────────────────────────────────────────

create or replace function public.claim_fcm_token()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- Clearing a token (sign-out) can never collide, and returning early here is
  -- also what stops the UPDATE below from recursing: it sets fcm_token to null,
  -- which re-enters this function and stops on this line.
  if new.fcm_token is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.fcm_token is not distinct from new.fcm_token then
    return new;
  end if;

  update public.profiles
     set fcm_token = null,
         fcm_token_updated_at = null
   where fcm_token = new.fcm_token
     and id <> new.id;

  return new;
end;
$$;

revoke execute on function public.claim_fcm_token() from public, anon, authenticated;

drop trigger if exists profiles_claim_fcm_token on public.profiles;
create trigger profiles_claim_fcm_token
before insert or update of fcm_token on public.profiles
for each row execute function public.claim_fcm_token();

-- Repair what already leaked. Newest registration wins, matching the trigger;
-- a row with no fcm_token_updated_at predates that column being written and is
-- therefore the older of any pair.
with ranked as (
  select id,
         row_number() over (
           partition by fcm_token
           order by fcm_token_updated_at desc nulls last, created_at desc
         ) as rn
    from public.profiles
   where fcm_token is not null
)
update public.profiles p
   set fcm_token = null,
       fcm_token_updated_at = null
  from ranked r
 where p.id = r.id
   and r.rn > 1;

create unique index if not exists profiles_fcm_token_unique
  on public.profiles (fcm_token)
  where fcm_token is not null;
