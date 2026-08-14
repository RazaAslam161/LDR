-- Dual-consent deletion was a UI convention, not a rule.
--
-- memory_threads_delete_member allowed a plain DELETE by either partner on any
-- row in their couple, so the whole request -> confirm -> delete flow could be
-- bypassed with a single PostgREST call. One partner could erase a shared
-- memory unilaterally and permanently — exactly what the design says must be
-- impossible. A consent model only the client honours is not a consent model.
drop policy if exists memory_threads_delete_member on public.memory_threads;
revoke delete on public.memory_threads from authenticated, anon;

-- The proposer must be immutable, or "the other partner accepts" is not a check
-- at all: with UPDATE permitted couple-wide, either side could rewrite proposer
-- to their partner's id and then accept their own proposal.
create or replace function public.memory_threads_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
  if new.proposer is distinct from old.proposer then
    raise exception 'proposer is immutable';
  end if;
  if new.couple_id is distinct from old.couple_id then
    raise exception 'couple_id is immutable';
  end if;
  if new.state = 'accepted' and old.state = 'proposed'
     and new.accepted_by = old.proposer then
    raise exception 'a proposal must be accepted by the other partner';
  end if;
  return new;
end $function$;

drop trigger if exists memory_threads_guard_trg on public.memory_threads;
create trigger memory_threads_guard_trg
  before update on public.memory_threads
  for each row execute function public.memory_threads_guard();
