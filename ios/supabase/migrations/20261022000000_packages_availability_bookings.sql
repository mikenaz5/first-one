-- Packages, availability, imported calendar busy time and bookings.
--
-- The guarantee this migration exists to provide: a creator can never be double-booked.
-- It holds even if two clients tap "Book" at the same instant, because the database itself
-- (an exclusion constraint) refuses overlapping bookings, not just the app.
--
-- Bookings can't be written directly. Clients call create_booking(), which re-validates the
-- time against the creator's hours, blackouts, notice and buffer and computes the price from
-- the creator's package. Nothing about price or duration is taken from the client.

create extension if not exists btree_gist;

-- ---------------------------------------------------------------------------
-- packages
-- ---------------------------------------------------------------------------
create table public.packages (
  id               uuid primary key default gen_random_uuid(),
  creator_id       uuid not null references public.creator_profiles (id) on delete cascade,
  name             text not null check (char_length(btrim(name)) between 2 and 60),
  summary          text not null default '' check (char_length(summary) <= 500),
  -- Raw value of the app's Specialty enum, or null.
  category         text,
  price_cents      integer not null check (price_cents > 0 and price_cents <= 100000000),
  currency_code    text not null default 'USD' check (currency_code ~ '^[A-Z]{3}$'),
  duration_minutes integer not null check (duration_minutes between 15 and 1440 and duration_minutes % 15 = 0),
  deliverables     text[] not null default '{}' check (cardinality(deliverables) <= 12),
  turnaround_days  integer not null default 14 check (turnaround_days between 1 and 90),
  -- Fixed amount due at booking. Add-ons are settled in the balance.
  deposit_cents    integer not null default 0,
  -- [{ "id", "kind", "name", "priceCents", "extraMinutes", "turnaroundDeltaDays" }], same shape as the app's AddOn.
  add_ons          jsonb not null default '[]'::jsonb
                     check (jsonb_typeof(add_ons) = 'array' and jsonb_array_length(add_ons) <= 8),
  -- Hidden packages are drafts: only the creator can see them.
  is_published     boolean not null default true,
  position         integer not null default 0 check (position >= 0),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint deposit_within_price check (deposit_cents >= 0 and deposit_cents <= price_cents)
);

create index packages_creator_position_idx on public.packages (creator_id, position);

create trigger packages_set_updated_at
  before update on public.packages
  for each row execute function public.set_updated_at();

alter table public.packages enable row level security;

create policy "Published packages are public; creators see their own"
  on public.packages for select
  using (is_published or (select auth.uid()) = creator_id);

create policy "Creators add their own packages"
  on public.packages for insert
  to authenticated
  with check ((select auth.uid()) = creator_id);

create policy "Creators edit their own packages"
  on public.packages for update
  to authenticated
  using ((select auth.uid()) = creator_id)
  with check ((select auth.uid()) = creator_id);

create policy "Creators delete their own packages"
  on public.packages for delete
  to authenticated
  using ((select auth.uid()) = creator_id);

-- ---------------------------------------------------------------------------
-- availability_settings (one row per creator)
-- ---------------------------------------------------------------------------
create table public.availability_settings (
  creator_id            uuid primary key references public.creator_profiles (id) on delete cascade,
  -- IANA name, for example 'America/Chicago'. All hours below are local to it.
  time_zone             text not null,
  -- Open days only: [{ "weekday": 2, "window": { "startMinute": 540, "endMinute": 1020 } }]
  -- weekday: 1 = Sunday ... 7 = Saturday. A weekday with no entry is closed.
  weekly                jsonb not null default '[]'::jsonb
                          check (jsonb_typeof(weekly) = 'array' and jsonb_array_length(weekly) <= 7),
  -- [{ "id", "start": "2026-12-24", "end": "2026-12-26", "reason" }], inclusive local dates.
  blackouts             jsonb not null default '[]'::jsonb
                          check (jsonb_typeof(blackouts) = 'array' and jsonb_array_length(blackouts) <= 200),
  min_notice_hours      integer not null default 24 check (min_notice_hours between 0 and 720),
  max_advance_days      integer not null default 180 check (max_advance_days between 1 and 730),
  -- Required gap after each booking.
  buffer_minutes        integer not null default 30 check (buffer_minutes between 0 and 240),
  slot_interval_minutes integer not null default 30 check (slot_interval_minutes in (15, 30, 60)),
  updated_at            timestamptz not null default now()
);

create or replace function public.validate_time_zone()
returns trigger
language plpgsql
as $$
begin
  -- Raises "time zone ... not recognized" for a bad name, so create_booking can rely on it.
  perform now() at time zone new.time_zone;
  return new;
end;
$$;

create trigger availability_settings_validate_time_zone
  before insert or update on public.availability_settings
  for each row execute function public.validate_time_zone();

create trigger availability_settings_set_updated_at
  before update on public.availability_settings
  for each row execute function public.set_updated_at();

alter table public.availability_settings enable row level security;

-- Clients need the hours to show open times.
create policy "Availability is public"
  on public.availability_settings for select
  using (true);

create policy "Creators add their own availability"
  on public.availability_settings for insert
  to authenticated
  with check ((select auth.uid()) = creator_id);

create policy "Creators edit their own availability"
  on public.availability_settings for update
  to authenticated
  using ((select auth.uid()) = creator_id)
  with check ((select auth.uid()) = creator_id);

create policy "Creators delete their own availability"
  on public.availability_settings for delete
  to authenticated
  using ((select auth.uid()) = creator_id);

-- ---------------------------------------------------------------------------
-- busy_blocks: time imported from the creator's own calendar
-- ---------------------------------------------------------------------------
-- Only start and end times, never titles or details. Clients can't read this table;
-- they get ranges through get_busy_intervals().
create table public.busy_blocks (
  id         uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.creator_profiles (id) on delete cascade,
  starts_at  timestamptz not null,
  ends_at    timestamptz not null,
  constraint busy_block_order check (ends_at > starts_at)
);

create index busy_blocks_creator_idx on public.busy_blocks (creator_id, starts_at);

alter table public.busy_blocks enable row level security;

create policy "Creators read their own busy time"
  on public.busy_blocks for select
  to authenticated
  using ((select auth.uid()) = creator_id);

create policy "Creators add their own busy time"
  on public.busy_blocks for insert
  to authenticated
  with check ((select auth.uid()) = creator_id);

create policy "Creators delete their own busy time"
  on public.busy_blocks for delete
  to authenticated
  using ((select auth.uid()) = creator_id);

-- ---------------------------------------------------------------------------
-- bookings
-- ---------------------------------------------------------------------------
create type public.booking_status as enum ('held', 'confirmed', 'cancelled', 'completed', 'expired');

create table public.bookings (
  id            uuid primary key default gen_random_uuid(),
  creator_id    uuid not null references public.creator_profiles (id) on delete cascade,
  -- Kept (as null) if a client deletes their account, so the creator's records survive.
  client_id     uuid references auth.users (id) on delete set null,
  -- Names are snapshots, so the booking still reads correctly after profile edits.
  creator_name  text not null,
  client_name   text not null default '',
  package_id    uuid references public.packages (id) on delete set null,
  package_name  text not null,
  -- [{ "id", "name", "priceCents", "extraMinutes" }] as booked.
  add_ons       jsonb not null default '[]'::jsonb,
  start_at      timestamptz not null,
  -- End of the shoot itself.
  end_at        timestamptz not null,
  -- End of the shoot plus the creator's buffer. No other booking may overlap [start_at, blocked_until).
  blocked_until timestamptz not null,
  time_zone     text not null,
  currency_code text not null,
  total_cents   integer not null check (total_cents >= 0),
  deposit_cents integer not null check (deposit_cents >= 0),
  status        public.booking_status not null default 'confirmed',
  notes         text not null default '' check (char_length(notes) <= 500),
  created_at    timestamptz not null default now(),
  constraint bookings_time_order check (start_at < end_at and end_at <= blocked_until),
  constraint bookings_deposit_within_total check (deposit_cents <= total_cents),
  -- The double-booking guard. Two active bookings for one creator can't overlap in time.
  -- Half-open ranges: a booking may start exactly when the previous one's buffer ends.
  constraint bookings_no_overlap exclude using gist (
    creator_id with =,
    tstzrange(start_at, blocked_until, '[)') with &&
  ) where (status in ('held', 'confirmed'))
);

create index bookings_creator_start_idx on public.bookings (creator_id, start_at);
create index bookings_client_start_idx on public.bookings (client_id, start_at);

alter table public.bookings enable row level security;

-- Deliberately no insert/update/delete policies: all writes go through the functions below.
create policy "People see bookings they are part of"
  on public.bookings for select
  to authenticated
  using ((select auth.uid()) = client_id or (select auth.uid()) = creator_id);

-- ---------------------------------------------------------------------------
-- create_booking
-- ---------------------------------------------------------------------------
-- Errors are raised as plain tokens that the app maps to messages:
--   not_signed_in, package_unavailable, cannot_book_yourself, slot_unavailable, slot_taken
create or replace function public.create_booking(
  p_package_id uuid,
  p_add_on_ids uuid[],
  p_start_at   timestamptz,
  p_client_name text default '',
  p_notes      text default ''
)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid           uuid := auth.uid();
  v_requested     uuid[] := coalesce(p_add_on_ids, '{}');
  v_pkg           public.packages;
  v_settings      public.availability_settings;
  v_creator_name  text;
  v_add_on        jsonb;
  v_add_ons       jsonb := '[]'::jsonb;
  v_found         integer := 0;
  v_extra_minutes integer := 0;
  v_add_on_total  integer := 0;
  v_duration      integer;
  v_total         integer;
  v_deposit       integer;
  v_end           timestamptz;
  v_blocked_until timestamptz;
  v_local         timestamp;
  v_day           date;
  v_weekday       integer;
  v_start_minute  integer;
  v_end_minute    integer;
  v_win_start     integer;
  v_win_end       integer;
  v_row           public.bookings;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;

  select * into v_pkg from public.packages where id = p_package_id and is_published;
  if not found then
    raise exception 'package_unavailable';
  end if;
  if v_pkg.creator_id = v_uid then
    raise exception 'cannot_book_yourself';
  end if;

  select * into v_settings from public.availability_settings where creator_id = v_pkg.creator_id;
  if not found then
    raise exception 'slot_unavailable';
  end if;

  -- Add-ons come from the creator's package, matched by id. The client's own numbers are never used.
  for v_add_on in select value from jsonb_array_elements(v_pkg.add_ons) loop
    if (v_add_on->>'id')::uuid = any (v_requested) then
      v_found := v_found + 1;
      v_extra_minutes := v_extra_minutes + coalesce((v_add_on->>'extraMinutes')::integer, 0);
      v_add_on_total := v_add_on_total + coalesce((v_add_on->>'priceCents')::integer, 0);
      v_add_ons := v_add_ons || jsonb_build_array(jsonb_build_object(
        'id', v_add_on->>'id',
        'name', v_add_on->>'name',
        'priceCents', coalesce((v_add_on->>'priceCents')::integer, 0),
        'extraMinutes', coalesce((v_add_on->>'extraMinutes')::integer, 0)
      ));
    end if;
  end loop;
  if v_found <> (select count(distinct id) from unnest(v_requested) as id) then
    raise exception 'package_unavailable';
  end if;

  v_duration := v_pkg.duration_minutes + v_extra_minutes;
  v_end := p_start_at + make_interval(mins => v_duration);
  v_blocked_until := v_end + make_interval(mins => v_settings.buffer_minutes);

  -- Local wall-clock time in the creator's zone; every rule below is expressed in it.
  v_local := p_start_at at time zone v_settings.time_zone;
  v_day := v_local::date;
  v_weekday := extract(dow from v_local)::integer + 1; -- dow: 0 = Sunday, so +1 gives 1 = Sunday
  v_start_minute := extract(hour from v_local)::integer * 60 + extract(minute from v_local)::integer;
  v_end_minute := v_start_minute + v_duration;

  if extract(second from v_local) <> 0 then
    raise exception 'slot_unavailable';
  end if;

  -- Minimum notice and how far ahead people may book.
  if p_start_at < now() + make_interval(hours => v_settings.min_notice_hours) then
    raise exception 'slot_unavailable';
  end if;
  if v_day > (now() at time zone v_settings.time_zone)::date + v_settings.max_advance_days then
    raise exception 'slot_unavailable';
  end if;

  -- Working hours: the whole booking must fit in the day's window, on the offered grid.
  select (e->'window'->>'startMinute')::integer, (e->'window'->>'endMinute')::integer
    into v_win_start, v_win_end
    from jsonb_array_elements(v_settings.weekly) as e
   where (e->>'weekday')::integer = v_weekday
   limit 1;
  if v_win_start is null
     or v_start_minute < v_win_start
     or v_end_minute > v_win_end
     or (v_start_minute - v_win_start) % v_settings.slot_interval_minutes <> 0 then
    raise exception 'slot_unavailable';
  end if;

  -- Blackout dates (inclusive).
  if exists (
    select 1 from jsonb_array_elements(v_settings.blackouts) as b
     where v_day between (b->>'start')::date and (b->>'end')::date
  ) then
    raise exception 'slot_unavailable';
  end if;

  -- Time the creator marked busy in their own calendar (advisory: it is only as fresh as their last sync).
  if exists (
    select 1 from public.busy_blocks bb
     where bb.creator_id = v_pkg.creator_id
       and tstzrange(bb.starts_at, bb.ends_at + make_interval(mins => v_settings.buffer_minutes), '[)')
           && tstzrange(p_start_at, v_blocked_until, '[)')
  ) then
    raise exception 'slot_unavailable';
  end if;

  v_total := v_pkg.price_cents + v_add_on_total;
  v_deposit := least(v_pkg.deposit_cents, v_total);

  select display_name into v_creator_name from public.creator_profiles where id = v_pkg.creator_id;

  begin
    insert into public.bookings (
      creator_id, client_id, creator_name, client_name, package_id, package_name, add_ons,
      start_at, end_at, blocked_until, time_zone, currency_code, total_cents, deposit_cents,
      status, notes
    ) values (
      v_pkg.creator_id, v_uid, coalesce(v_creator_name, 'Creator'), left(coalesce(p_client_name, ''), 80),
      v_pkg.id, v_pkg.name, v_add_ons,
      p_start_at, v_end, v_blocked_until, v_settings.time_zone, v_pkg.currency_code, v_total, v_deposit,
      'confirmed', left(coalesce(p_notes, ''), 500)
    )
    returning * into v_row;
  exception
    when exclusion_violation then
      -- Another booking overlaps. This is what protects against two simultaneous requests.
      raise exception 'slot_taken';
  end;

  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- cancel_booking
-- ---------------------------------------------------------------------------
create or replace function public.cancel_booking(p_booking_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.bookings;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;

  select * into v_row from public.bookings where id = p_booking_id for update;
  if not found
     or (v_row.client_id is distinct from v_uid and v_row.creator_id <> v_uid)
     or v_row.status not in ('held', 'confirmed')
     or v_row.start_at <= now() then
    raise exception 'not_cancellable';
  end if;

  update public.bookings set status = 'cancelled' where id = p_booking_id returning * into v_row;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- get_busy_intervals
-- ---------------------------------------------------------------------------
-- Lets any signed-in client see *when* a creator is unavailable, without seeing who booked or why.
create or replace function public.get_busy_intervals(
  p_creator_id uuid,
  p_from       timestamptz,
  p_to         timestamptz
)
returns table (starts_at timestamptz, ends_at timestamptz, kind text)
language sql
stable
security definer
set search_path = public
as $$
  select b.start_at, b.blocked_until, 'booking'::text
    from public.bookings b
   where b.creator_id = p_creator_id
     and b.status in ('held', 'confirmed')
     and tstzrange(b.start_at, b.blocked_until, '[)') && tstzrange(p_from, p_to, '[)')
  union all
  select bb.starts_at, bb.ends_at, 'external'::text
    from public.busy_blocks bb
   where bb.creator_id = p_creator_id
     and tstzrange(bb.starts_at, bb.ends_at, '[)') && tstzrange(p_from, p_to, '[)');
$$;

-- Only signed-in users may call these. (Functions are executable by everyone by default.)
revoke execute on function public.create_booking(uuid, uuid[], timestamptz, text, text) from public, anon;
revoke execute on function public.cancel_booking(uuid) from public, anon;
revoke execute on function public.get_busy_intervals(uuid, timestamptz, timestamptz) from public, anon;
grant execute on function public.create_booking(uuid, uuid[], timestamptz, text, text) to authenticated;
grant execute on function public.cancel_booking(uuid) to authenticated;
grant execute on function public.get_busy_intervals(uuid, timestamptz, timestamptz) to authenticated;
