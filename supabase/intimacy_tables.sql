-- ───────────────────────────────────────────────────────────────────────────
-- Miles — intimacy layer tables
-- Run AFTER schema.sql AND intimacy_additions.sql.
-- Idempotent.
-- ───────────────────────────────────────────────────────────────────────────

-- ─── Dual-consent gate (shared by all intimacy features) ────────────────────
create table if not exists public.consent_state (
  couple_id    uuid not null references public.couples(id) on delete cascade,
  feature      text not null,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  granted      boolean not null default false,
  granted_at   timestamptz,
  revoked_at   timestamptz,
  primary key (couple_id, feature, user_id)
);
create index if not exists consent_couple_feature_idx
  on public.consent_state(couple_id, feature);

-- ─── Desire Temperature (F5) ────────────────────────────────────────────────
create table if not exists public.desire_temps (
  couple_id  uuid not null references public.couples(id) on delete cascade,
  on_date    date not null,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  score      int not null check (score between 1 and 10),
  primary key (couple_id, on_date, user_id)
);

-- ─── Mood Lamp (F6) — last color per partner ────────────────────────────────
create table if not exists public.mood_lamp (
  couple_id   uuid not null references public.couples(id) on delete cascade,
  user_id     uuid not null references public.profiles(id) on delete cascade,
  color_rgb   int not null check (color_rgb between 0 and 16777215),
  updated_at  timestamptz not null default now(),
  primary key (couple_id, user_id)
);

-- ─── Fantasy Jar (F2) ───────────────────────────────────────────────────────
create table if not exists public.fantasy_jar_entries (
  id           uuid primary key default gen_random_uuid(),
  couple_id    uuid not null references public.couples(id) on delete cascade,
  author       uuid not null references public.profiles(id) on delete cascade,
  ciphertext   bytea not null,
  nonce        bytea not null,
  tag_hashes   text[] not null default '{}',
  created_at   timestamptz not null default now()
);
create index if not exists fantasy_couple_idx
  on public.fantasy_jar_entries(couple_id);

create table if not exists public.fantasy_jar_reveals (
  couple_id      uuid not null references public.couples(id) on delete cascade,
  entry_pair     text not null,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  revealed_at    timestamptz default now(),
  primary key (couple_id, entry_pair, user_id)
);

-- ─── Afterglow (F3) ─────────────────────────────────────────────────────────
create table if not exists public.afterglow_entries (
  id           uuid primary key default gen_random_uuid(),
  couple_id    uuid not null references public.couples(id) on delete cascade,
  happened_at  timestamptz not null,
  gratitude_a  bytea, nonce_a bytea, photo_a bytea,
  gratitude_b  bytea, nonce_b bytea, photo_b bytea,
  retention    text not null default 'ephemeral',
  sealed_at    timestamptz,
  created_at   timestamptz not null default now()
);

-- ─── Private Vault (F4) ─────────────────────────────────────────────────────
create table if not exists public.vault_items (
  id              uuid primary key default gen_random_uuid(),
  couple_id       uuid not null references public.couples(id) on delete cascade,
  kind            text not null,                  -- 'photo' | 'note' | 'voice' | 'trace'
  ciphertext      bytea not null,
  nonce           bytea not null,
  ad              text,
  created_by      uuid not null references public.profiles(id),
  created_at      timestamptz not null default now(),
  retention       text not null default 'keep',
  reconfirm_due   timestamptz,
  delete_requested boolean not null default false,
  delete_requested_by uuid references public.profiles(id),
  delete_requested_at timestamptz,
  deleted         boolean not null default false,
  deleted_by      uuid references public.profiles(id),
  deleted_at      timestamptz
);
create index if not exists vault_couple_idx on public.vault_items(couple_id);
create index if not exists vault_reconfirm_idx
  on public.vault_items(reconfirm_due)
  where retention = 'ephemeral' and deleted = false;

-- ─── Body Map (F7) ──────────────────────────────────────────────────────────
create table if not exists public.body_map_pins (
  id          uuid primary key default gen_random_uuid(),
  couple_id   uuid not null references public.couples(id) on delete cascade,
  author      uuid not null references public.profiles(id) on delete cascade,
  x           real not null check (x between 0 and 1),
  y           real not null check (y between 0 and 1),
  note_cipher bytea not null,
  note_nonce  bytea not null,
  created_at  timestamptz not null default now()
);
create index if not exists bodymap_couple_idx
  on public.body_map_pins(couple_id);

-- ─── "Pick for us" dice (F8) ────────────────────────────────────────────────
create table if not exists public.dice_rolls (
  id           uuid primary key default gen_random_uuid(),
  couple_id    uuid not null references public.couples(id) on delete cascade,
  rolled_at    timestamptz not null default now(),
  tier         text not null,
  result_tags  text[] not null default '{}'
);

create table if not exists public.dice_tier_consents (
  couple_id    uuid not null references public.couples(id) on delete cascade,
  tier         text not null,
  user_id      uuid not null references public.profiles(id) on delete cascade,
  granted      boolean not null default false,
  granted_at   timestamptz,
  primary key (couple_id, tier, user_id)
);

-- ─── Memory Threads (F9) ────────────────────────────────────────────────────
create table if not exists public.memory_threads (
  id           uuid primary key default gen_random_uuid(),
  couple_id    uuid not null references public.couples(id) on delete cascade,
  proposer     uuid not null references public.profiles(id) on delete cascade,
  title_cipher bytea not null, title_nonce bytea not null,
  happened_on  date not null,
  photo_cipher bytea, photo_nonce bytea,
  note_cipher  bytea, note_nonce bytea,
  state        text not null default 'proposed',
  accepted_by  uuid references public.profiles(id),
  accepted_at  timestamptz,
  archived_at  timestamptz,
  created_at   timestamptz not null default now()
);
create index if not exists memory_couple_state_idx
  on public.memory_threads(couple_id, state);

create table if not exists public.memory_revisits (
  memory_id    uuid primary key references public.memory_threads(id) on delete cascade,
  initiated_by uuid not null references public.profiles(id) on delete cascade,
  initiated_at timestamptz not null default now(),
  partner_acknowledged_at timestamptz
);

-- ─── Couple dissolution (breakup purge, §5.4) ───────────────────────────────
create table if not exists public.couple_dissolutions (
  couple_id    uuid primary key references public.couples(id) on delete cascade,
  initiated_by uuid not null references public.profiles(id),
  initiated_at timestamptz not null default now(),
  purge_at     timestamptz not null,
  cancelled_at timestamptz
);

-- ─── RLS ────────────────────────────────────────────────────────────────────
-- All intimacy tables are couple-scoped. Reuse the same membership pattern
-- as schema.sql: a user may only read/write rows tied to their couple.

alter table public.consent_state          enable row level security;
alter table public.desire_temps           enable row level security;
alter table public.mood_lamp             enable row level security;
alter table public.fantasy_jar_entries    enable row level security;
alter table public.fantasy_jar_reveals    enable row level security;
alter table public.afterglow_entries      enable row level security;
alter table public.vault_items            enable row level security;
alter table public.body_map_pins          enable row level security;
alter table public.dice_rolls             enable row level security;
alter table public.dice_tier_consents     enable row level security;
alter table public.memory_threads         enable row level security;
alter table public.memory_revisits        enable row level security;
alter table public.couple_dissolutions    enable row level security;

do $$
declare t text;
begin
  foreach t in array array[
    'consent_state','desire_temps','mood_lamp','fantasy_jar_entries',
    'fantasy_jar_reveals','afterglow_entries','vault_items','body_map_pins',
    'dice_rolls','dice_tier_consents','memory_threads','couple_dissolutions'
  ]
  loop
    execute format(
      'drop policy if exists "%1$s_select_member" on public.%1$s;'
      'create policy "%1$s_select_member" on public.%1$s '
      'for select using (couple_id = public.current_user_couple_id());',
      t
    );
    execute format(
      'drop policy if exists "%1$s_insert_member" on public.%1$s;'
      'create policy "%1$s_insert_member" on public.%1$s '
      'for insert with check (couple_id = public.current_user_couple_id());',
      t
    );
    execute format(
      'drop policy if exists "%1$s_update_member" on public.%1$s;'
      'create policy "%1$s_update_member" on public.%1$s '
      'for update using (couple_id = public.current_user_couple_id()) '
      'with check (couple_id = public.current_user_couple_id());',
      t
    );
    execute format(
      'drop policy if exists "%1$s_delete_member" on public.%1$s;'
      'create policy "%1$s_delete_member" on public.%1$s '
      'for delete using (couple_id = public.current_user_couple_id());',
      t
    );
  end loop;
end $$;

-- memory_revisits is keyed on memory_id, not couple_id — joins via memory_threads
drop policy if exists "memory_revisits_select_member" on public.memory_revisits;
create policy "memory_revisits_select_member" on public.memory_revisits
  for select using (memory_id in (
    select id from public.memory_threads
    where couple_id = public.current_user_couple_id()
  ));
drop policy if exists "memory_revisits_insert_member" on public.memory_revisits;
create policy "memory_revisits_insert_member" on public.memory_revisits
  for insert with check (memory_id in (
    select id from public.memory_threads
    where couple_id = public.current_user_couple_id()
  ));
drop policy if exists "memory_revisits_update_member" on public.memory_revisits;
create policy "memory_revisits_update_member" on public.memory_revisits
  for update using (memory_id in (
    select id from public.memory_threads
    where couple_id = public.current_user_couple_id()
  ));
drop policy if exists "memory_revisits_delete_member" on public.memory_revisits;
create policy "memory_revisits_delete_member" on public.memory_revisits
  for delete using (memory_id in (
    select id from public.memory_threads
    where couple_id = public.current_user_couple_id()
  ));

-- ─── Comments ───────────────────────────────────────────────────────────────
comment on table public.consent_state is 'Per-feature dual-consent gate for the Closer intimacy module.';
comment on table public.vault_items is 'End-to-end encrypted Private Vault items. ciphertext + nonce only; NEVER plaintext.';
comment on table public.memory_threads is 'Encrypted intimacy milestones. Sits behind its own PIN gate in-app.';
