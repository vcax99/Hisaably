-- Hisaably — Phase 2: core schema
-- Tables, enums, constraints and indexes. RLS policies, grants and RPCs are
-- added in Phase 3. Until then no client role (anon/authenticated) has any
-- privilege on these tables, and RLS is enabled with no policies, so the data
-- is unreachable from the app.
--
-- Money: NUMERIC(14,2), never float. Dates for accounting: DATE in Asia/Kolkata.
-- Transactions are collective: no created_by / user_id / member_id, by design.

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.app_role as enum ('SUPER_ADMIN', 'USER');
create type public.record_status as enum ('ACTIVE', 'DISABLED');
create type public.group_role as enum ('MEMBER', 'GROUP_ADMIN');
create type public.transaction_type as enum ('INCOME', 'EXPENSE');
create type public.device_platform as enum ('ANDROID', 'IOS');
create type public.notification_type as enum (
  'EXPENSE_ADDED', 'INCOME_ADDED', 'MONTH_STARTED', 'MONTHLY_SUMMARY'
);

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------

-- Business "today" is always India Standard Time, whatever the server's timezone.
create function public.ist_today()
returns date
language sql
stable
set search_path = ''
as $$
  select (now() at time zone 'Asia/Kolkata')::date;
$$;

create function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- profiles (1:1 with auth.users; credentials live only in Supabase Auth)
-- ---------------------------------------------------------------------------
create table public.profiles (
  id          uuid primary key references auth.users (id) on delete cascade,
  name        text not null,
  -- Login identifier (owner decision C). Lowercase, 3–30 chars, letters/digits
  -- with inner dots/underscores. Unique across all users.
  username    text not null,
  email       text,
  role        public.app_role not null default 'USER',
  status      public.record_status not null default 'ACTIVE',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint profiles_name_length check (char_length(btrim(name)) between 1 and 80),
  constraint profiles_username_format
    check (username ~ '^[a-z0-9]([a-z0-9._]{1,28})[a-z0-9]$'),
  constraint profiles_username_key unique (username)
);

create index profiles_role_status_idx on public.profiles (role, status);

create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- groups
-- ---------------------------------------------------------------------------
create table public.groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  status      public.record_status not null default 'ACTIVE',
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint groups_name_length check (char_length(btrim(name)) between 1 and 60)
);

create trigger groups_set_updated_at
  before update on public.groups
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- group_members
-- ---------------------------------------------------------------------------
create table public.group_members (
  id          uuid primary key default gen_random_uuid(),
  group_id    uuid not null references public.groups (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  group_role  public.group_role not null default 'MEMBER',
  status      public.record_status not null default 'ACTIVE',
  joined_at   timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint group_members_group_user_key unique (group_id, user_id)
);

create index group_members_user_status_idx on public.group_members (user_id, status);
create index group_members_group_status_idx on public.group_members (group_id, status);

create trigger group_members_set_updated_at
  before update on public.group_members
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- group_categories (owner decision 8: per-group category lists)
-- is_active = false means "deleted": hidden for new entries, while past
-- transactions keep their category text.
-- ---------------------------------------------------------------------------
create table public.group_categories (
  id          uuid primary key default gen_random_uuid(),
  group_id    uuid not null references public.groups (id) on delete cascade,
  type        public.transaction_type not null,
  name        text not null,
  is_active   boolean not null default true,
  sort_order  integer not null default 100,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint group_categories_name_length check (char_length(btrim(name)) between 1 and 40)
);

-- Case-insensitive uniqueness per group and type ("Food" = "food").
create unique index group_categories_group_type_name_key
  on public.group_categories (group_id, type, lower(btrim(name)));

create trigger group_categories_set_updated_at
  before update on public.group_categories
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- transactions (collective ledger — source of truth for all balances)
-- id is generated on the client so offline sync can be idempotent.
-- ---------------------------------------------------------------------------
create table public.transactions (
  id                uuid primary key default gen_random_uuid(),
  group_id          uuid not null references public.groups (id) on delete restrict,
  type              public.transaction_type not null,
  amount            numeric(14, 2) not null,
  category          text,
  description       text,
  transaction_date  date not null,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  sync_version      bigint not null default 1,
  -- Soft delete (owner decision 1) so other devices' caches learn about deletions.
  deleted_at        timestamptz,
  constraint transactions_amount_positive check (amount > 0),
  constraint transactions_category_length
    check (category is null or char_length(btrim(category)) between 1 and 40),
  constraint transactions_expense_needs_category
    check (type = 'INCOME' or category is not null),
  constraint transactions_description_length
    check (description is null or char_length(description) <= 500),
  constraint transactions_date_floor check (transaction_date >= date '2000-01-01')
);

-- Composite indexes cover group_id-only lookups, date/month range scans and
-- keyset pagination (transaction_date desc, created_at desc, id desc).
create index transactions_group_date_idx
  on public.transactions (group_id, transaction_date desc, created_at desc, id desc);
create index transactions_group_type_date_idx
  on public.transactions (group_id, type, transaction_date desc, created_at desc, id desc);

-- Owner decision 6: no future-dated transactions (IST). A trigger, not a CHECK,
-- because "today" isn't immutable.
create function public.transactions_before_write()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.transaction_date > public.ist_today() then
    raise exception 'Transaction date cannot be in the future'
      using errcode = 'check_violation', hint = 'FUTURE_DATE';
  end if;

  if tg_op = 'UPDATE' then
    new.sync_version := old.sync_version + 1;
    new.created_at := old.created_at;
  end if;

  return new;
end;
$$;

create trigger transactions_before_insert
  before insert on public.transactions
  for each row execute function public.transactions_before_write();

create trigger transactions_before_update
  before update on public.transactions
  for each row
  when (old.* is distinct from new.*)
  execute function public.transactions_before_write();

create trigger transactions_set_updated_at
  before update on public.transactions
  for each row
  when (old.* is distinct from new.*)
  execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- monthly_summaries (DERIVED CACHE — never the source of truth)
-- ---------------------------------------------------------------------------
create table public.monthly_summaries (
  id               uuid primary key default gen_random_uuid(),
  group_id         uuid not null references public.groups (id) on delete cascade,
  year             integer not null,
  month            integer not null,
  opening_balance  numeric(14, 2) not null default 0,
  total_income     numeric(14, 2) not null default 0,
  total_expense    numeric(14, 2) not null default 0,
  closing_balance  numeric(14, 2) not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint monthly_summaries_month_range check (month between 1 and 12),
  constraint monthly_summaries_year_range check (year between 2000 and 2200),
  constraint monthly_summaries_balance_formula
    check (closing_balance = opening_balance + total_income - total_expense),
  constraint monthly_summaries_group_period_key unique (group_id, year, month)
);

create trigger monthly_summaries_set_updated_at
  before update on public.monthly_summaries
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- notification_devices (a user may have several devices)
-- ---------------------------------------------------------------------------
create table public.notification_devices (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  device_token  text not null,
  platform      public.device_platform not null,
  is_active     boolean not null default true,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint notification_devices_token_length
    check (char_length(device_token) between 1 and 4096),
  constraint notification_devices_user_token_key unique (user_id, device_token)
);

-- Lookups by token (move a token between users, deactivate invalid tokens).
create index notification_devices_token_idx on public.notification_devices (device_token);

create trigger notification_devices_set_updated_at
  before update on public.notification_devices
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- notifications (history + read state)
-- ---------------------------------------------------------------------------
create table public.notifications (
  id              uuid primary key default gen_random_uuid(),
  group_id        uuid references public.groups (id) on delete cascade,
  recipient_id    uuid not null references public.profiles (id) on delete cascade,
  transaction_id  uuid references public.transactions (id) on delete set null,
  type            public.notification_type not null,
  title           text not null,
  body            text not null,
  is_read         boolean not null default false,
  -- Idempotency key (e.g. 'MONTH_STARTED:<group>:<yyyy-mm>:<recipient>').
  dedupe_key      text,
  created_at      timestamptz not null default now(),
  constraint notifications_dedupe_key_key unique (dedupe_key)
);

create index notifications_recipient_read_created_idx
  on public.notifications (recipient_id, is_read, created_at desc);

-- ---------------------------------------------------------------------------
-- Defence in depth: RLS on every table (the project's automatic-RLS setting
-- already does this; being explicit keeps the migration self-contained).
-- ---------------------------------------------------------------------------
alter table public.profiles             enable row level security;
alter table public.groups               enable row level security;
alter table public.group_members        enable row level security;
alter table public.group_categories     enable row level security;
alter table public.transactions         enable row level security;
alter table public.monthly_summaries    enable row level security;
alter table public.notification_devices enable row level security;
alter table public.notifications        enable row level security;
