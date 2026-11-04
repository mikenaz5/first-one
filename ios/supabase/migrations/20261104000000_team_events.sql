-- Team events, and calendar links.
--
-- 1. A company can put events on its team calendar that have nothing to do with a booking: a team meeting, a day of
--    editing, a day off, a trip to see a venue. Owners, Admins, Managers and Creators can add one; the person who made
--    it can change or remove it, and Owners, Admins and Managers can change or remove anyone's. Viewers can see them.
--    Everyone in the company sees every event (the team calendar already shows everyone's day).
--    An event is for the whole team or for the people named, and by default it takes their time: nobody can be booked
--    by a client while they are in it. An event can say it doesn't ("blocks_bookings" off) and then it is only a note on
--    the calendar. A booking that is already there is never touched by an event added over it.
--
-- 2. Calendar links. Each person can get one private web address that other calendar apps (Apple Calendar, Google
--    Calendar, Outlook, anything that can subscribe to a calendar) read, to show their bookings and the team events they
--    are in. The address holds a secret; resetting it stops the old one working. The Edge Function calendar-feed turns
--    the data below into the calendar file.

-- ---------------------------------------------------------------------------
-- Two new permissions. SPEC.md 4.3 and SlateTests/Fixtures/team_permissions.json hold the same table.
-- (org_perm_for already lists what still works when a plan has lapsed; these two are not in it, so a lapsed company
-- can read its events but not add or change them.)
-- ---------------------------------------------------------------------------
create or replace function public.org_role_allows(p_role text, p_perm text)
returns boolean
language sql
immutable
as $$
  select exists (
    select 1
      from (values
        ('company.delete',           array['owner']),
        ('billing.manage',           array['owner']),
        ('payments.connect',         array['owner']),
        ('payouts.split',            array['owner']),
        ('company.edit',             array['owner', 'admin']),
        ('team.invite',              array['owner', 'admin']),
        ('team.manage',              array['owner', 'admin']),
        ('services.manage',          array['owner', 'admin']),
        ('templates.manage',         array['owner', 'admin']),
        ('signer.designate',         array['owner', 'admin']),
        ('activity.view',            array['owner', 'admin']),
        ('bookings.assign',          array['owner', 'admin', 'manager']),
        ('bookings.manage',          array['owner', 'admin', 'manager']),
        ('bookings.view_all',        array['owner', 'admin', 'manager', 'viewer']),
        ('reports.view',             array['owner', 'admin', 'manager', 'viewer']),
        ('bookings.manage_assigned', array['owner', 'admin', 'manager', 'creator']),
        ('calendar.manage_own',      array['owner', 'admin', 'manager', 'creator']),
        ('events.add',               array['owner', 'admin', 'manager', 'creator']),
        ('events.manage_all',        array['owner', 'admin', 'manager']),
        ('calendar.view_team',       array['owner', 'admin', 'manager', 'creator', 'viewer']),
        ('team.view',                array['owner', 'admin', 'manager', 'creator', 'viewer'])
      ) as m (perm, roles)
     where m.perm = p_perm and p_role = any (m.roles)
  );
$$;

-- ---------------------------------------------------------------------------
-- The numbers the app shares (SlateTests/Fixtures/event_rules.json holds the same ones and both test suites check them)
-- ---------------------------------------------------------------------------
create or replace function public.app_event_title_max() returns integer language sql immutable as $$ select 80 $$;
create or replace function public.app_event_notes_max() returns integer language sql immutable as $$ select 500 $$;
create or replace function public.app_event_location_max() returns integer language sql immutable as $$ select 120 $$;
-- The longest one event may run, for a trip or a stretch of leave.
create or replace function public.app_event_max_days() returns integer language sql immutable as $$ select 31 $$;
-- How many events that haven't ended a company may have at once.
create or replace function public.app_event_max_upcoming() returns integer language sql immutable as $$ select 500 $$;
-- How many people one event can name.
create or replace function public.app_event_max_people() returns integer language sql immutable as $$ select 50 $$;

-- A title or place as it is kept: one line, no control characters, single spaces, no space at either end. Mirrors
-- EventRules.cleanLine in Swift; the shared fixture checks both.
create or replace function public.event_clean_line(p_text text)
returns text
language sql
immutable
as $$ select btrim(regexp_replace(public.message_clean(p_text), '[ \t\n]+', ' ', 'g')) $$;

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
create table public.team_events (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  title           text not null check (char_length(title) between 1 and 80),
  notes           text not null default '' check (char_length(notes) <= 500),
  location        text not null default '' check (char_length(location) <= 120),
  starts_at       timestamptz not null,
  ends_at         timestamptz not null,
  -- Only changes how it is drawn: the times already run from midnight to midnight in the company's time zone.
  all_day         boolean not null default false,
  -- For the whole team. When false, the people are in team_event_members.
  everyone        boolean not null default true,
  -- Whether the people it is for can be booked by a client during it.
  blocks_bookings boolean not null default true,
  created_by      uuid references auth.users (id) on delete set null,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint team_events_times check (ends_at > starts_at and ends_at - starts_at <= interval '31 days')
);
create index team_events_org_idx on public.team_events (organization_id, starts_at);

create table public.team_event_members (
  event_id uuid not null references public.team_events (id) on delete cascade,
  user_id  uuid not null references auth.users (id) on delete cascade,
  primary key (event_id, user_id)
);
create index team_event_members_user_idx on public.team_event_members (user_id);

alter table public.team_events enable row level security;
alter table public.team_event_members enable row level security;

-- Reading only. Events are written by the functions below.
create policy "The team reads its events"
  on public.team_events for select
  to authenticated
  using (public.acts_for(organization_id, 'calendar.view_team'));

create policy "The team reads who an event is for"
  on public.team_event_members for select
  to authenticated
  using (exists (select 1 from public.team_events e where e.id = event_id));

revoke insert, update, delete, truncate on public.team_events, public.team_event_members from anon, authenticated;

-- ---------------------------------------------------------------------------
-- An event as the app reads it
-- ---------------------------------------------------------------------------
-- member_ids is the people it is for who are still in the team; it is empty when it is for everyone. can_edit is
-- whether the caller may change or remove it.
create or replace function public.team_event_json(e public.team_events)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'id', e.id,
    'organization_id', e.organization_id,
    'title', e.title,
    'notes', e.notes,
    'location', e.location,
    'starts_at', e.starts_at,
    'ends_at', e.ends_at,
    'all_day', e.all_day,
    'everyone', e.everyone,
    'blocks_bookings', e.blocks_bookings,
    'member_ids', case when e.everyone then '[]'::jsonb else coalesce((
        select jsonb_agg(m.user_id order by m.user_id)
          from public.team_event_members m
          join public.memberships ms on ms.organization_id = e.organization_id and ms.user_id = m.user_id and ms.removed_at is null
         where m.event_id = e.id), '[]'::jsonb) end,
    'created_by', e.created_by,
    'created_by_name', public.person_name(e.created_by),
    'can_edit', coalesce(
        (e.created_by = auth.uid() and public.org_perm_for(auth.uid(), e.organization_id, 'events.add'))
        or public.org_perm_for(auth.uid(), e.organization_id, 'events.manage_all'),
        false)
  )
$$;

-- ---------------------------------------------------------------------------
-- Add or change an event
-- ---------------------------------------------------------------------------
-- p_event_id null adds one. p_member_ids is who it is for when p_everyone is false (at least one person, all of them in
-- the team). Returns the event.
create or replace function public.team_event_save(
  p_org        uuid,
  p_event_id   uuid,
  p_title      text,
  p_notes      text,
  p_location   text,
  p_starts_at  timestamptz,
  p_ends_at    timestamptz,
  p_all_day    boolean,
  p_everyone   boolean,
  p_member_ids uuid[],
  p_blocks     boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := public.require_user();
  v_title    text := public.event_clean_line(p_title);
  v_notes    text := public.message_clean(p_notes);
  v_location text := public.event_clean_line(p_location);
  v_ids      uuid[];
  v_e        public.team_events;
begin
  if public.org_role_of(v_uid, p_org) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'events.add') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;

  if p_event_id is not null then
    select * into v_e from public.team_events where id = p_event_id and organization_id = p_org for update;
    if not found then
      raise exception 'not_found';
    end if;
    -- The person who made it, or the people who run the calendar. (created_by is null if its author left.)
    if not (coalesce(v_e.created_by = v_uid, false) or public.acts_for(p_org, 'events.manage_all')) then
      raise exception 'not_allowed' using errcode = '42501';
    end if;
  end if;

  if v_title = '' or p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then
    raise exception 'invalid_event';
  end if;
  if char_length(v_title) > public.app_event_title_max()
     or char_length(v_notes) > public.app_event_notes_max()
     or char_length(v_location) > public.app_event_location_max() then
    raise exception 'event_text_too_long';
  end if;
  if p_ends_at - p_starts_at > make_interval(days => public.app_event_max_days()) then
    raise exception 'event_too_long';
  end if;

  if coalesce(p_everyone, true) then
    v_ids := '{}';
  else
    select coalesce(array_agg(distinct x), '{}') into v_ids from unnest(coalesce(p_member_ids, '{}')) x;
    if cardinality(v_ids) = 0 or cardinality(v_ids) > public.app_event_max_people() then
      raise exception 'invalid_event';
    end if;
    if exists (select 1 from unnest(v_ids) x where public.org_role_of(x, p_org) is null) then
      raise exception 'invalid_attendee';
    end if;
  end if;

  if p_event_id is null then
    if (select count(*) from public.team_events where organization_id = p_org and ends_at > now()) >= public.app_event_max_upcoming() then
      raise exception 'too_many_events';
    end if;
    insert into public.team_events (organization_id, title, notes, location, starts_at, ends_at, all_day, everyone, blocks_bookings, created_by)
    values (p_org, v_title, v_notes, v_location, p_starts_at, p_ends_at, coalesce(p_all_day, false), coalesce(p_everyone, true),
            coalesce(p_blocks, true), v_uid)
    returning * into v_e;
    perform public.activity_add(p_org, 'event.created', 'event', v_e.id, 'Added the event "' || v_e.title || '"');
  else
    update public.team_events
       set title = v_title, notes = v_notes, location = v_location, starts_at = p_starts_at, ends_at = p_ends_at,
           all_day = coalesce(p_all_day, false), everyone = coalesce(p_everyone, true), blocks_bookings = coalesce(p_blocks, true),
           updated_at = now()
     where id = v_e.id
     returning * into v_e;
    perform public.activity_add(p_org, 'event.updated', 'event', v_e.id, 'Changed the event "' || v_e.title || '"');
  end if;

  delete from public.team_event_members where event_id = v_e.id;
  insert into public.team_event_members (event_id, user_id) select v_e.id, x from unnest(v_ids) x;

  return public.team_event_json(v_e);
end;
$$;

create or replace function public.team_event_delete(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
  v_e   public.team_events;
begin
  select * into v_e from public.team_events where id = p_event_id for update;
  if not found or public.org_role_of(v_uid, v_e.organization_id) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(v_e.organization_id, 'events.add') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if not (coalesce(v_e.created_by = v_uid, false) or public.acts_for(v_e.organization_id, 'events.manage_all')) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  delete from public.team_events where id = v_e.id;
  perform public.activity_add(v_e.organization_id, 'event.deleted', 'event', v_e.id, 'Removed the event "' || v_e.title || '"');
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading them
-- ---------------------------------------------------------------------------
-- Every event in the window (at most 62 days), for the team calendar.
create or replace function public.team_events_list(p_org uuid, p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
  v_to  timestamptz := least(p_to, p_from + interval '62 days');
begin
  if public.org_role_of(v_uid, p_org) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'calendar.view_team') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return coalesce((
    select jsonb_agg(public.team_event_json(e) order by e.starts_at, e.id)
      from public.team_events e
     where e.organization_id = p_org and tstzrange(e.starts_at, e.ends_at, '[)') && tstzrange(p_from, v_to, '[)')
  ), '[]'::jsonb);
end;
$$;

-- The events of every company the caller is in that are for them: for the whole team, or naming them. For putting them
-- in the phone's own calendar. At most 400 days.
create or replace function public.my_team_events(p_from timestamptz, p_to timestamptz)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
  v_to  timestamptz := least(p_to, p_from + interval '400 days');
begin
  return coalesce((
    select jsonb_agg(public.team_event_json(e) || jsonb_build_object('organization_name', coalesce(p.display_name, '')) order by e.starts_at, e.id)
      from public.team_events e
      left join public.creator_profiles p on p.id = e.organization_id
     where public.org_perm_for(v_uid, e.organization_id, 'calendar.view_team')
       and (e.everyone or exists (select 1 from public.team_event_members m where m.event_id = e.id and m.user_id = v_uid))
       and tstzrange(e.starts_at, e.ends_at, '[)') && tstzrange(p_from, v_to, '[)')
  ), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------------
-- A team event that blocks bookings takes the time of the people it is for
-- ---------------------------------------------------------------------------
-- Whether a person can take a booking then (create_booking asks), who is free (team_availability tells the booking
-- page) and what the team calendar draws as busy. Each is the function as it was, with events counted as busy time.
create or replace function public.member_slot_state(
  p_org           uuid,
  p_user          uuid,
  p_member_weekly jsonb,
  p_settings      public.availability_settings,
  p_start         timestamptz,
  p_end           timestamptz,
  p_blocked_until timestamptz,
  p_ignore        uuid default null
)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_local   timestamp := p_start at time zone p_settings.time_zone;
  v_weekday integer := extract(dow from v_local)::integer + 1;
  v_start   integer := extract(hour from v_local)::integer * 60 + extract(minute from v_local)::integer;
  v_end     integer := v_start + (extract(epoch from (p_end - p_start)) / 60)::integer;
  v_cs      integer;
  v_ce      integer;
  v_ms      integer;
  v_me      integer;
begin
  select (e -> 'window' ->> 'startMinute')::integer, (e -> 'window' ->> 'endMinute')::integer into v_cs, v_ce
    from jsonb_array_elements(p_settings.weekly) e where (e ->> 'weekday')::integer = v_weekday limit 1;
  if v_cs is null then
    return 'slot_unavailable';
  end if;
  if p_member_weekly is not null then
    select (e -> 'window' ->> 'startMinute')::integer, (e -> 'window' ->> 'endMinute')::integer into v_ms, v_me
      from jsonb_array_elements(p_member_weekly) e where (e ->> 'weekday')::integer = v_weekday limit 1;
    if v_ms is null then
      return 'slot_unavailable';
    end if;
    v_cs := greatest(v_cs, v_ms);
    v_ce := least(v_ce, v_me);
  end if;
  if v_start < v_cs or v_end > v_ce or (v_start - v_cs) % p_settings.slot_interval_minutes <> 0 then
    return 'slot_unavailable';
  end if;

  if exists (
    select 1 from public.busy_blocks bb
     where bb.creator_id = p_user
       and tstzrange(bb.starts_at, bb.ends_at + make_interval(mins => p_settings.buffer_minutes), '[)')
           && tstzrange(p_start, p_blocked_until, '[)')
  ) then
    return 'slot_unavailable';
  end if;

  -- A team event that blocks bookings takes the time of everyone it is for (the whole team, or the people named).
  if exists (
    select 1 from public.team_events e
     where e.organization_id = p_org and e.blocks_bookings
       and tstzrange(e.starts_at, e.ends_at + make_interval(mins => p_settings.buffer_minutes), '[)')
           && tstzrange(p_start, p_blocked_until, '[)')
       and (e.everyone or exists (select 1 from public.team_event_members m where m.event_id = e.id and m.user_id = p_user))
  ) then
    return 'slot_unavailable';
  end if;

  if exists (
    select 1 from public.bookings b
     where b.assigned_to = p_user
       and (b.status = 'confirmed' or (b.status = 'held' and b.hold_expires_at > now()))
       and b.id is distinct from p_ignore
       and tstzrange(b.start_at, b.blocked_until, '[)') && tstzrange(p_start, p_blocked_until, '[)')
  ) then
    return 'slot_taken';
  end if;
  return 'ok';
end;
$$;

create or replace function public.team_availability(p_package_id uuid, p_member_id uuid default null, p_from timestamptz default now(), p_to timestamptz default now() + interval '45 days')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pkg      public.packages;
  v_settings public.availability_settings;
  v_org      public.organizations;
  v_to       timestamptz := least(p_to, p_from + interval '92 days');
begin
  perform public.require_user();
  select * into v_pkg from public.packages where id = p_package_id and is_published;
  select * into v_org from public.organizations where id = v_pkg.creator_id;
  select * into v_settings from public.availability_settings where creator_id = v_pkg.creator_id;
  if v_pkg.id is null or v_org.id is null or v_settings.creator_id is null or not public.org_billing_ok(v_org.id) then
    raise exception 'package_unavailable';
  end if;
  perform public.expire_holds(v_org.id);

  return jsonb_build_object(
    'settings', to_jsonb(v_settings),
    'assignment_mode', v_org.assignment_mode,
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', c.user_id,
               'display_name', coalesce(p.display_name, ''),
               'weekly', public.effective_weekly(v_settings.weekly, c.weekly),
               'busy', coalesce((
                 select jsonb_agg(jsonb_build_object('starts_at', x.s, 'ends_at', x.e) order by x.s)
                   from (
                     select b.start_at s, b.blocked_until e from public.bookings b
                      where b.assigned_to = c.user_id
                        and (b.status = 'confirmed' or (b.status = 'held' and b.hold_expires_at > now()))
                        and tstzrange(b.start_at, b.blocked_until, '[)') && tstzrange(p_from, v_to, '[)')
                     union all
                     select bb.starts_at, bb.ends_at + make_interval(mins => v_settings.buffer_minutes) from public.busy_blocks bb
                      where bb.creator_id = c.user_id
                        and tstzrange(bb.starts_at, bb.ends_at + make_interval(mins => v_settings.buffer_minutes), '[)') && tstzrange(p_from, v_to, '[)')
                     union all
                     select e.starts_at, e.ends_at + make_interval(mins => v_settings.buffer_minutes) from public.team_events e
                      where e.organization_id = v_org.id and e.blocks_bookings
                        and (e.everyone or exists (select 1 from public.team_event_members tm where tm.event_id = e.id and tm.user_id = c.user_id))
                        and tstzrange(e.starts_at, e.ends_at + make_interval(mins => v_settings.buffer_minutes), '[)') && tstzrange(p_from, v_to, '[)')
                   ) x), '[]'::jsonb)
             ) order by c.joined_at, c.user_id)
        from public.package_candidates(v_pkg.id, p_member_id) c
        left join public.creator_profiles p on p.id = c.user_id and p.kind = 'person'
    ), '[]'::jsonb),
    'unassigned', coalesce((
      select jsonb_agg(jsonb_build_object('starts_at', b.start_at, 'ends_at', b.blocked_until) order by b.start_at)
        from public.bookings b
       where b.creator_id = v_org.id and b.assigned_to is null
         and (b.status = 'confirmed' or (b.status = 'held' and b.hold_expires_at > now()))
         and tstzrange(b.start_at, b.blocked_until, '[)') && tstzrange(p_from, v_to, '[)')
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.team_calendar(p_org uuid, p_from timestamptz, p_to timestamptz, p_member_ids uuid[] default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid      uuid := public.require_user();
  v_settings public.availability_settings;
  v_to       timestamptz := least(p_to, p_from + interval '62 days');
begin
  if public.org_role_of(v_uid, p_org) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'calendar.view_team') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  select * into v_settings from public.availability_settings where creator_id = p_org;

  return jsonb_build_object(
    'time_zone', v_settings.time_zone,
    'members', coalesce((
      select jsonb_agg(jsonb_build_object(
               'user_id', m.user_id,
               'display_name', coalesce(p.display_name, ''),
               'avatar_path', p.avatar_path,
               'role', m.role,
               'title', m.title,
               'bookable', m.bookable,
               'weekly', case when m.bookable then public.effective_weekly(v_settings.weekly, m.weekly) else '[]'::jsonb end,
               'busy', coalesce((
                 select jsonb_agg(jsonb_build_object('starts_at', x.s, 'ends_at', x.e, 'kind', x.k) order by x.s)
                   from (
                     select bb.starts_at s, bb.ends_at e, 'external'::text k from public.busy_blocks bb
                      where bb.creator_id = m.user_id and tstzrange(bb.starts_at, bb.ends_at, '[)') && tstzrange(p_from, v_to, '[)')
                     union all
                     select b.start_at, b.blocked_until, 'personal'::text from public.bookings b
                      where b.assigned_to = m.user_id and b.creator_id <> p_org
                        and (b.status = 'confirmed' or (b.status = 'held' and b.hold_expires_at > now()))
                        and tstzrange(b.start_at, b.blocked_until, '[)') && tstzrange(p_from, v_to, '[)')
                     union all
                     select e.starts_at, e.ends_at, 'event'::text from public.team_events e
                      where e.organization_id = p_org and e.blocks_bookings
                        and (e.everyone or exists (select 1 from public.team_event_members tm where tm.event_id = e.id and tm.user_id = m.user_id))
                        and tstzrange(e.starts_at, e.ends_at, '[)') && tstzrange(p_from, v_to, '[)')
                   ) x), '[]'::jsonb),
               'bookings', coalesce((
                 select jsonb_agg(jsonb_build_object(
                          'id', case when public.provider_view(b.creator_id, b.assigned_to) then b.id end,
                          'start_at', b.start_at, 'end_at', b.end_at, 'blocked_until', b.blocked_until,
                          'status', b.status,
                          'package_name', case when public.provider_view(b.creator_id, b.assigned_to) then b.package_name end,
                          'client_name', case when public.provider_view(b.creator_id, b.assigned_to) then b.client_name end,
                          'requested_member', b.requested_member
                        ) order by b.start_at)
                   from public.bookings b
                  where b.creator_id = p_org and b.assigned_to = m.user_id
                    and (b.status = 'confirmed' or (b.status = 'held' and b.hold_expires_at > now()))
                    and tstzrange(b.start_at, b.blocked_until, '[)') && tstzrange(p_from, v_to, '[)')), '[]'::jsonb)
             ) order by case m.role when 'owner' then 0 when 'admin' then 1 when 'manager' then 2 else 3 end,
                        lower(coalesce(p.display_name, '')), m.user_id)
        from public.memberships m
        left join public.creator_profiles p on p.id = m.user_id and p.kind = 'person'
       where m.organization_id = p_org and m.removed_at is null and m.role <> 'viewer'
         and (p_member_ids is null or m.user_id = any (p_member_ids))
    ), '[]'::jsonb),
    'unassigned', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', case when public.provider_view(b.creator_id, b.assigned_to) then b.id end,
               'start_at', b.start_at, 'end_at', b.end_at, 'blocked_until', b.blocked_until, 'status', b.status,
               'package_name', case when public.provider_view(b.creator_id, b.assigned_to) then b.package_name end,
               'client_name', case when public.provider_view(b.creator_id, b.assigned_to) then b.client_name end
             ) order by b.start_at)
        from public.bookings b
       where b.creator_id = p_org and b.assigned_to is null
         and (b.status = 'confirmed' or (b.status = 'held' and b.hold_expires_at > now()))
         and tstzrange(b.start_at, b.blocked_until, '[)') && tstzrange(p_from, v_to, '[)')
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Calendar links
-- ---------------------------------------------------------------------------
-- One secret per person. Whoever has the address can read the calendar; nobody can change anything through it.
create table public.calendar_feeds (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  token      text not null unique check (token ~ '^[0-9a-f]{32}$'),
  created_at timestamptz not null default now(),
  rotated_at timestamptz
);
alter table public.calendar_feeds enable row level security;
revoke all on public.calendar_feeds from anon, authenticated;

-- The caller's secret, made the first time it is asked for.
create or replace function public.calendar_feed_token()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := public.require_user();
  v_token text;
begin
  select token into v_token from public.calendar_feeds where user_id = v_uid;
  if v_token is null then
    insert into public.calendar_feeds (user_id, token)
    values (v_uid, encode(extensions.gen_random_bytes(16), 'hex'))
    on conflict (user_id) do nothing;
    select token into v_token from public.calendar_feeds where user_id = v_uid;
  end if;
  return v_token;
end;
$$;

-- A new secret. The old address stops working at once.
create or replace function public.calendar_feed_reset()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := public.require_user();
  v_token text := encode(extensions.gen_random_bytes(16), 'hex');
begin
  insert into public.calendar_feeds (user_id, token) values (v_uid, v_token)
  on conflict (user_id) do update set token = excluded.token, rotated_at = now();
  return v_token;
end;
$$;

-- What the calendar file is made from, for the Edge Function (the service role). Null for a secret nobody has. The
-- person's own bookings (as the person doing the job, or as the client; confirmed or done, from 60 days ago to 400 days
-- ahead) and the team events that are for them. No money, no contract, no notes of a booking and no contact details.
create or replace function public.calendar_feed_data(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid  uuid;
  v_from timestamptz := now() - interval '60 days';
  v_to   timestamptz := now() + interval '400 days';
begin
  select user_id into v_uid from public.calendar_feeds where token = p_token;
  if v_uid is null then
    return null;
  end if;
  return jsonb_build_object(
    'bookings', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', b.id, 'package_name', b.package_name, 'start_at', b.start_at, 'end_at', b.end_at,
               'time_zone', b.time_zone,
               'role', case when b.assigned_to = v_uid then 'provider' else 'client' end,
               'client_name', b.client_name, 'creator_name', b.creator_name, 'status', b.status
             ) order by b.start_at, b.id)
        from public.bookings b
       where (b.assigned_to = v_uid or b.client_id = v_uid)
         and b.status in ('confirmed', 'completed')
         and b.start_at >= v_from and b.start_at < v_to
    ), '[]'::jsonb),
    'events', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', e.id, 'title', e.title, 'notes', e.notes, 'location', e.location, 'starts_at', e.starts_at,
               'ends_at', e.ends_at, 'all_day', e.all_day, 'organization_name', coalesce(p.display_name, ''),
               'time_zone', coalesce(s.time_zone, 'UTC'), 'updated_at', e.updated_at
             ) order by e.starts_at, e.id)
        from public.team_events e
        left join public.creator_profiles p on p.id = e.organization_id
        left join public.availability_settings s on s.creator_id = e.organization_id
       where public.org_perm_for(v_uid, e.organization_id, 'calendar.view_team')
         and (e.everyone or exists (select 1 from public.team_event_members m where m.event_id = e.id and m.user_id = v_uid))
         and e.ends_at >= v_from and e.starts_at < v_to
    ), '[]'::jsonb)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function
  public.team_event_json(public.team_events),
  public.calendar_feed_data(text)
from public, anon, authenticated;

revoke execute on function
  public.team_event_save(uuid, uuid, text, text, text, timestamptz, timestamptz, boolean, boolean, uuid[], boolean),
  public.team_event_delete(uuid),
  public.team_events_list(uuid, timestamptz, timestamptz),
  public.my_team_events(timestamptz, timestamptz),
  public.calendar_feed_token(),
  public.calendar_feed_reset()
from public, anon;
grant execute on function
  public.team_event_save(uuid, uuid, text, text, text, timestamptz, timestamptz, boolean, boolean, uuid[], boolean),
  public.team_event_delete(uuid),
  public.team_events_list(uuid, timestamptz, timestamptz),
  public.my_team_events(timestamptz, timestamptz),
  public.calendar_feed_token(),
  public.calendar_feed_reset()
to authenticated;
