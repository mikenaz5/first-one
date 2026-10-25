-- Company accounts, part 1: organizations, memberships, invites, roles and the activity log.
--
-- A company is a row in creator_profiles with kind = 'company' (its public page: name, logo, bio, portfolio,
-- location) plus a row in organizations (the administrative record). The company's profile id *is* its organization
-- id, so every table that already points at creator_profiles (packages, bookings, contracts, payment accounts...) can
-- be owned by a person or by a company with a real foreign key. A person's profile id is still their user id.
--
-- Who may do what is decided here, in the database, from the memberships table. The app hides what a role can't do,
-- but nothing the app sends can widen it. Part 2 (company_booking) applies the same checks to services, bookings,
-- contracts and payments.

-- ---------------------------------------------------------------------------
-- Settings: the numbers that are meant to be changed without touching rules code
-- ---------------------------------------------------------------------------
-- Closed to the API. Read through the functions below; change a value with an UPDATE as the service role.
create table public.app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  constraint seat_limits_make_sense check (
    key <> 'seats' or (
      (value ->> 'minimum')::integer between 1 and 1000
      and (value ->> 'maximum')::integer between (value ->> 'minimum')::integer and 100000
    )
  ),
  constraint invite_days_make_sense check (key <> 'invites' or (value ->> 'expiry_days')::integer between 1 and 90),
  constraint grace_days_make_sense check (key <> 'billing' or (value ->> 'grace_days')::integer between 0 and 60)
);
alter table public.app_settings enable row level security;
revoke all on public.app_settings from anon, authenticated;

insert into public.app_settings (key, value) values
  ('seats',   '{"minimum": 10, "maximum": 250}'),
  ('invites', '{"expiry_days": 7}'),
  ('billing', '{"grace_days": 7}');

create or replace function public.app_setting_int(p_key text, p_field text, p_default integer)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (value ->> p_field)::integer from public.app_settings where key = p_key), p_default);
$$;

create or replace function public.app_seat_minimum() returns integer language sql stable security definer set search_path = public as
  $$ select public.app_setting_int('seats', 'minimum', 10) $$;
create or replace function public.app_seat_maximum() returns integer language sql stable security definer set search_path = public as
  $$ select public.app_setting_int('seats', 'maximum', 250) $$;
create or replace function public.app_invite_days() returns integer language sql stable security definer set search_path = public as
  $$ select public.app_setting_int('invites', 'expiry_days', 7) $$;
create or replace function public.app_grace_days() returns integer language sql stable security definer set search_path = public as
  $$ select public.app_setting_int('billing', 'grace_days', 7) $$;

-- What the app shows and checks against, so the numbers aren't hard-coded there.
create or replace function public.team_config()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'seat_minimum', public.app_seat_minimum(),
    'seat_maximum', public.app_seat_maximum(),
    'invite_expiry_days', public.app_invite_days(),
    'grace_days', public.app_grace_days()
  );
$$;

-- ---------------------------------------------------------------------------
-- creator_profiles can now be a person or a company
-- ---------------------------------------------------------------------------
-- A person's profile id is their user id, kept real by user_id (which cascades on account deletion). A company has
-- no user, so its id stands alone.
alter table public.creator_profiles drop constraint creator_profiles_id_fkey;

alter table public.creator_profiles
  add column kind    text not null default 'person' check (kind in ('person', 'company')),
  add column user_id uuid references auth.users (id) on delete cascade;

update public.creator_profiles set user_id = id;

alter table public.creator_profiles
  add constraint creator_profiles_owner_shape check (
    (kind = 'person' and user_id = id) or (kind = 'company' and user_id is null)
  );

create or replace function public.creator_profiles_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'INSERT' then
    if new.kind = 'person' and new.user_id is null then
      new.user_id := new.id;
    end if;
  else
    -- What a profile is, and whose it is, never changes.
    new.kind := old.kind;
    new.user_id := old.user_id;
  end if;
  return new;
end;
$$;

create trigger creator_profiles_guard
  before insert or update on public.creator_profiles
  for each row execute function public.creator_profiles_guard();

-- ---------------------------------------------------------------------------
-- organizations
-- ---------------------------------------------------------------------------
create table public.organizations (
  -- Equal to the company's creator_profiles id.
  id                   uuid primary key references public.creator_profiles (id) on delete restrict,
  legal_name           text not null check (char_length(btrim(legal_name)) between 2 and 120),
  legal_address        text not null default '' check (char_length(legal_address) <= 300),
  created_by           uuid references auth.users (id) on delete set null,
  -- 'auto' picks a free member when a client books the company; 'manual' holds the booking for a Manager.
  assignment_mode      text not null default 'auto' check (assignment_mode in ('auto', 'manual')),
  -- Roles that may be designated to countersign. The Owner can always sign; this only widens it.
  signer_roles         text[] not null default '{owner,admin}'
                         check (signer_roles <@ array['owner', 'admin', 'manager'] and 'owner' = any (signer_roles)),
  signer_user_id       uuid references auth.users (id) on delete set null,
  signer_title         text not null default '' check (char_length(signer_title) <= 80),
  signer_designated_by uuid references auth.users (id) on delete set null,
  signer_authorized_at timestamptz,
  -- Whether each booking records the assigned member's share (a ledger for reports; no money moves).
  split_enabled        boolean not null default false,
  state                text not null default 'active' check (state in ('active', 'lapsed', 'closed')),
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now(),
  closed_at            timestamptz,
  constraint signer_needs_authorisation check ((signer_user_id is null) = (signer_authorized_at is null)),
  constraint closed_has_a_date check ((state = 'closed') = (closed_at is not null))
);

create trigger organizations_set_updated_at
  before update on public.organizations
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- memberships
-- ---------------------------------------------------------------------------
create table public.memberships (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  user_id         uuid not null references auth.users (id) on delete cascade,
  role            text not null check (role in ('owner', 'admin', 'manager', 'creator', 'viewer')),
  title           text not null default '' check (char_length(title) <= 80),
  -- Shown on the company page, and open to direct bookings.
  listed          boolean not null default true,
  bookable        boolean not null default true,
  -- This member's share of each booking they are assigned, in basis points. A ledger, not a transfer.
  share_bps       integer not null default 0 check (share_bps between 0 and 10000),
  joined_at       timestamptz not null default now(),
  removed_at      timestamptz,
  removed_by      uuid references auth.users (id) on delete set null,
  constraint viewers_are_not_bookable check (role <> 'viewer' or not bookable)
);

create unique index memberships_one_active_per_person
  on public.memberships (organization_id, user_id) where removed_at is null;
create unique index memberships_one_owner
  on public.memberships (organization_id) where role = 'owner' and removed_at is null;
create index memberships_user_idx on public.memberships (user_id) where removed_at is null;

-- ---------------------------------------------------------------------------
-- invites
-- ---------------------------------------------------------------------------
-- The token is shown once, when the invite is made. Only its hash is stored. Closed to the API: use the functions.
create table public.invites (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  role            text not null check (role in ('admin', 'manager', 'creator', 'viewer')),
  -- A label and an address for the Mail sheet. Never matched against the person who accepts (Hide My Email).
  email           text check (email is null or (char_length(email) <= 254 and email like '%@%')),
  token_hash      text not null unique,
  invited_by      uuid references auth.users (id) on delete set null,
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null,
  status          text not null default 'pending' check (status in ('pending', 'accepted', 'revoked')),
  accepted_by     uuid references auth.users (id) on delete set null,
  accepted_at     timestamptz,
  constraint accepted_has_a_person check ((status = 'accepted') = (accepted_at is not null))
);
create index invites_org_idx on public.invites (organization_id, created_at desc);

-- ---------------------------------------------------------------------------
-- activity_log: who changed what. Append only.
-- ---------------------------------------------------------------------------
create table public.activity_log (
  id              uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete restrict,
  -- No foreign key: the history outlives an account.
  actor_id        uuid,
  actor_name      text not null default '',
  action          text not null check (char_length(action) between 3 and 60),
  entity_type     text not null default '',
  entity_id       uuid,
  summary         text not null check (char_length(summary) between 1 and 300),
  metadata        jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now()
);
create index activity_log_org_idx on public.activity_log (organization_id, created_at desc, id);

create or replace function public.activity_log_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'activity_log is append only' using errcode = '42501';
end;
$$;

create trigger activity_log_no_changes
  before update or delete on public.activity_log
  for each row execute function public.activity_log_append_only();

-- ---------------------------------------------------------------------------
-- Roles and permissions
-- ---------------------------------------------------------------------------
-- The matrix from SPEC section 4.3. SlateTests/Fixtures/team_permissions.json holds the same table; both test
-- suites check it against this function and OrgPermission (Swift), so the three can't drift apart.
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
        ('calendar.view_team',       array['owner', 'admin', 'manager', 'creator', 'viewer']),
        ('team.view',                array['owner', 'admin', 'manager', 'creator', 'viewer'])
      ) as m (perm, roles)
     where m.perm = p_perm and p_role = any (m.roles)
  );
$$;

-- Who may give someone a role. The Owner changes anyone but themselves into anything but Owner (ownership has its own
-- action). An Admin works only on Managers, Creators and Viewers. Nobody changes their own role (checked by callers).
create or replace function public.org_can_assign_role(p_actor_role text, p_current_role text, p_new_role text)
returns boolean
language sql
immutable
as $$
  select case
    when p_actor_role = 'owner' then p_current_role <> 'owner' and p_new_role <> 'owner'
    when p_actor_role = 'admin' then p_current_role in ('manager', 'creator', 'viewer') and p_new_role in ('manager', 'creator', 'viewer')
    else false
  end;
$$;

-- Can this role act on (remove, edit) a member in this other role?
create or replace function public.org_can_manage_role(p_actor_role text, p_target_role text)
returns boolean
language sql
immutable
as $$
  select case
    when p_actor_role = 'owner' then p_target_role <> 'owner'
    when p_actor_role = 'admin' then p_target_role in ('manager', 'creator', 'viewer')
    else false
  end;
$$;

-- Internal: does this user hold the permission in this company right now? A lapsed company is read only except for
-- billing and closing it; a closed one allows nothing.
create or replace function public.org_perm_for(p_user uuid, p_org uuid, p_perm text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select public.org_role_allows(m.role, p_perm)
       and case o.state
             when 'active' then true
             when 'lapsed' then p_perm in ('bookings.view_all', 'reports.view', 'calendar.view_team', 'team.view',
                                           'activity.view', 'billing.manage', 'company.delete')
             else false
           end
      from public.memberships m
      join public.organizations o on o.id = m.organization_id
     where m.organization_id = p_org and m.user_id = p_user and m.removed_at is null
  ), false);
$$;

-- Internal: the user's active role in a company, or null.
create or replace function public.org_role_of(p_user uuid, p_org uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select m.role from public.memberships m
   where m.organization_id = p_org and m.user_id = p_user and m.removed_at is null;
$$;

-- The one question every policy asks: may the signed-in user act for this owner? An owner is a person (only they can)
-- or a company (members whose role holds the permission). Open to the API roles because policies call it; it only
-- ever answers about the caller.
create or replace function public.acts_for(p_owner uuid, p_perm text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null
     and (p_owner = auth.uid() or public.org_perm_for(auth.uid(), p_owner, p_perm));
$$;

create or replace function public.is_org_member(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select auth.uid() is not null and public.org_role_of(auth.uid(), p_org) is not null;
$$;

-- ---------------------------------------------------------------------------
-- Row level security
-- ---------------------------------------------------------------------------
alter table public.organizations enable row level security;
alter table public.memberships enable row level security;
alter table public.invites enable row level security;
alter table public.activity_log enable row level security;

-- Members read their company's record. Everything is changed through the functions below.
create policy "Members read their company"
  on public.organizations for select
  to authenticated
  using (public.is_org_member(id));

create policy "Members read their team"
  on public.memberships for select
  to authenticated
  using (user_id = (select auth.uid()) or public.acts_for(organization_id, 'team.view'));

create policy "Owners and admins read the activity log"
  on public.activity_log for select
  to authenticated
  using (public.acts_for(organization_id, 'activity.view'));

-- A member's share is money: the table shows everyone the roster but not the shares (member_list() shows the Owner).
revoke select on public.memberships from anon, authenticated;
grant select (id, organization_id, user_id, role, title, listed, bookable, joined_at, removed_at, removed_by)
  on public.memberships to authenticated;

-- invites: no policy at all. Tokens and hashes never leave through the table API; invite_list() answers instead.
revoke all on public.invites from anon, authenticated;

-- Profiles: a person edits their own, a company's are edited by its Owner and Admins.
drop policy "Creators insert their own profile" on public.creator_profiles;
drop policy "Creators update their own profile" on public.creator_profiles;
drop policy "Creators delete their own profile" on public.creator_profiles;

create policy "People insert their own profile"
  on public.creator_profiles for insert
  to authenticated
  with check ((select auth.uid()) = id and kind = 'person');

create policy "Owners edit their profile"
  on public.creator_profiles for update
  to authenticated
  using (public.acts_for(id, 'company.edit'))
  with check (public.acts_for(id, 'company.edit'));

-- Only people delete a profile. A company is closed, never deleted (its contracts keep naming it).
create policy "People delete their own profile"
  on public.creator_profiles for delete
  to authenticated
  using (kind = 'person' and (select auth.uid()) = id);

drop policy "Creators add to their own portfolio" on public.portfolio_items;
drop policy "Creators edit their own portfolio" on public.portfolio_items;
drop policy "Creators delete from their own portfolio" on public.portfolio_items;

create policy "Owners add to their portfolio"
  on public.portfolio_items for insert
  to authenticated
  with check (public.acts_for(creator_id, 'company.edit'));

create policy "Owners edit their portfolio"
  on public.portfolio_items for update
  to authenticated
  using (public.acts_for(creator_id, 'company.edit'))
  with check (public.acts_for(creator_id, 'company.edit'));

create policy "Owners delete from their portfolio"
  on public.portfolio_items for delete
  to authenticated
  using (public.acts_for(creator_id, 'company.edit'));

-- Storage: a folder is named after its owner's id, which is a user's or a company's.
create or replace function public.can_use_storage_folder(p_folder text)
returns boolean
language sql
stable
as $$
  select p_folder = (select auth.uid())::text
      or case when p_folder ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then public.acts_for(p_folder::uuid, 'company.edit')
              else false end;
$$;

drop policy "Creators upload to their own avatar folder" on storage.objects;
drop policy "Creators replace their own avatar files" on storage.objects;
drop policy "Creators delete their own avatar files" on storage.objects;
drop policy "Creators upload to their own portfolio folder" on storage.objects;
drop policy "Creators replace their own portfolio files" on storage.objects;
drop policy "Creators delete their own portfolio files" on storage.objects;

create policy "Owners upload to their avatar folder"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'avatars' and public.can_use_storage_folder((storage.foldername(name))[1]));

create policy "Owners replace their avatar files"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'avatars' and public.can_use_storage_folder((storage.foldername(name))[1]));

create policy "Owners delete their avatar files"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'avatars' and public.can_use_storage_folder((storage.foldername(name))[1]));

create policy "Owners upload to their portfolio folder"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'portfolio' and public.can_use_storage_folder((storage.foldername(name))[1]));

create policy "Owners replace their portfolio files"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'portfolio' and public.can_use_storage_folder((storage.foldername(name))[1]));

create policy "Owners delete their portfolio files"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'portfolio' and public.can_use_storage_folder((storage.foldername(name))[1]));

-- ---------------------------------------------------------------------------
-- Activity log writing
-- ---------------------------------------------------------------------------
create or replace function public.person_name(p_user uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select display_name from public.creator_profiles where id = p_user and kind = 'person'), '');
$$;

-- Internal. The actor is whoever is signed in; a webhook or a job has none and is logged as Slate Pro.
create or replace function public.activity_add(
  p_org         uuid,
  p_action      text,
  p_entity_type text,
  p_entity_id   uuid,
  p_summary     text,
  p_metadata    jsonb default '{}'::jsonb
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.activity_log (organization_id, actor_id, actor_name, action, entity_type, entity_id, summary, metadata)
  values (
    p_org,
    auth.uid(),
    case when auth.uid() is null then 'Slate Pro' else coalesce(nullif(public.person_name(auth.uid()), ''), 'Someone') end,
    p_action, coalesce(p_entity_type, ''), p_entity_id, left(p_summary, 300), coalesce(p_metadata, '{}'::jsonb)
  );
$$;

create or replace function public.activity_list(p_org uuid, p_limit integer default 50, p_before timestamptz default null)
returns table (
  id uuid, actor_id uuid, actor_name text, action text, entity_type text, entity_id uuid,
  summary text, metadata jsonb, created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.acts_for(p_org, 'activity.view') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return query
    select l.id, l.actor_id, l.actor_name, l.action, l.entity_type, l.entity_id, l.summary, l.metadata, l.created_at
      from public.activity_log l
     where l.organization_id = p_org and (p_before is null or l.created_at < p_before)
     order by l.created_at desc, l.id desc
     limit greatest(1, least(coalesce(p_limit, 50), 200));
end;
$$;

-- A company's own profile edits are logged by whoever made them.
create or replace function public.creator_profiles_log_company_edit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_changed text[] := '{}';
begin
  if new.kind <> 'company' then
    return new;
  end if;
  if new.display_name is distinct from old.display_name then v_changed := array_append(v_changed, 'name'); end if;
  if new.handle is distinct from old.handle then v_changed := array_append(v_changed, 'handle'); end if;
  if new.bio is distinct from old.bio then v_changed := array_append(v_changed, 'bio'); end if;
  if new.location_name is distinct from old.location_name then v_changed := array_append(v_changed, 'location'); end if;
  if new.specialties is distinct from old.specialties then v_changed := array_append(v_changed, 'specialties'); end if;
  if new.avatar_path is distinct from old.avatar_path then v_changed := array_append(v_changed, 'logo'); end if;
  if cardinality(v_changed) > 0 then
    perform public.activity_add(new.id, 'company.profile_updated', 'company', new.id,
      'Updated the company profile (' || array_to_string(v_changed, ', ') || ')',
      jsonb_build_object('fields', to_jsonb(v_changed)));
  end if;
  return new;
end;
$$;

create trigger creator_profiles_log_company_edit
  after update on public.creator_profiles
  for each row execute function public.creator_profiles_log_company_edit();

-- ---------------------------------------------------------------------------
-- Small helpers for the functions below
-- ---------------------------------------------------------------------------
create or replace function public.require_user()
returns uuid
language plpgsql
stable
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  return v_uid;
end;
$$;

-- Seats: used = active members, pending = open invites, billed = at least the floor.
create or replace function public.org_seat_counts(p_org uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'used', u.n,
    'pending', (select count(*) from public.invites i
                 where i.organization_id = p_org and i.status = 'pending' and i.expires_at > now()),
    'billed', greatest(public.app_seat_minimum(), u.n),
    'minimum', public.app_seat_minimum(),
    'maximum', public.app_seat_maximum()
  )
  from (select count(*)::integer as n from public.memberships where organization_id = p_org and removed_at is null) u;
$$;

create or replace function public.org_seats(p_org uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_user();
  if not public.is_org_member(p_org) then
    raise exception 'not_found';
  end if;
  return public.org_seat_counts(p_org);
end;
$$;

-- Can this company take another member right now? Billing tightens this in part 3.
create or replace function public.org_can_grow(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.organizations o where o.id = p_org and o.state = 'active');
$$;

-- Stops auto-countersign if the designated signer is no longer someone who may sign.
create or replace function public.org_revalidate_signer(p_org uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org  public.organizations;
  v_role text;
begin
  select * into v_org from public.organizations where id = p_org for update;
  if not found or v_org.signer_user_id is null then
    return;
  end if;
  v_role := public.org_role_of(v_org.signer_user_id, p_org);
  if v_role is null or not (v_role = any (v_org.signer_roles)) then
    update public.organizations
       set signer_user_id = null, signer_title = '', signer_designated_by = null, signer_authorized_at = null
     where id = p_org;
    perform public.activity_add(p_org, 'signer.cleared', 'company', p_org,
      'Auto-countersign stopped: ' || coalesce(nullif(public.person_name(v_org.signer_user_id), ''), 'the designated signer')
      || ' can no longer sign for the company');
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Accounts: what the switcher shows
-- ---------------------------------------------------------------------------
create or replace function public.my_accounts()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
  v_me  public.creator_profiles;
begin
  select * into v_me from public.creator_profiles where id = v_uid and kind = 'person';
  return jsonb_build_object(
    'personal', jsonb_build_object(
      'user_id', v_uid,
      'has_profile', v_me.id is not null,
      'display_name', v_me.display_name,
      'handle', v_me.handle,
      'avatar_path', v_me.avatar_path
    ),
    'companies', coalesce((
      select jsonb_agg(jsonb_build_object(
               'organization_id', o.id,
               'name', p.display_name,
               'handle', p.handle,
               'avatar_path', p.avatar_path,
               'role', m.role,
               'title', m.title,
               'state', o.state
             ) order by m.joined_at, o.id)
        from public.memberships m
        join public.organizations o on o.id = m.organization_id
        join public.creator_profiles p on p.id = o.id
       where m.user_id = v_uid and m.removed_at is null and o.state <> 'closed'
    ), '[]'::jsonb)
  );
end;
$$;

-- Everything the Team screens need about one company in a single call.
create or replace function public.org_overview(p_org uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
  v_org public.organizations;
  v_role text := public.org_role_of(v_uid, p_org);
  v_prof public.creator_profiles;
begin
  if v_role is null then
    raise exception 'not_found';
  end if;
  select * into v_org from public.organizations where id = p_org;
  select * into v_prof from public.creator_profiles where id = p_org;
  return jsonb_build_object(
    'organization_id', v_org.id,
    'name', v_prof.display_name,
    'handle', v_prof.handle,
    'avatar_path', v_prof.avatar_path,
    'bio', v_prof.bio,
    'location_name', v_prof.location_name,
    'specialties', to_jsonb(v_prof.specialties),
    'legal_name', v_org.legal_name,
    'legal_address', v_org.legal_address,
    'assignment_mode', v_org.assignment_mode,
    'signer_roles', to_jsonb(v_org.signer_roles),
    'signer_user_id', v_org.signer_user_id,
    'signer_title', v_org.signer_title,
    'split_enabled', v_org.split_enabled,
    'state', v_org.state,
    'my_role', v_role,
    'seats', public.org_seat_counts(p_org)
  );
end;
$$;

-- The team as its members see it.
create or replace function public.member_list(p_org uuid)
returns table (
  user_id uuid, role text, title text, listed boolean, bookable boolean, share_bps integer, joined_at timestamptz,
  display_name text, handle text, avatar_path text, is_signer boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
  v_role text := public.org_role_of(v_uid, p_org);
  v_money boolean;
begin
  if v_role is null then
    raise exception 'not_found';
  end if;
  v_money := public.org_role_allows(v_role, 'payouts.split');
  return query
    select m.user_id, m.role, m.title, m.listed, m.bookable,
           case when v_money then m.share_bps else 0 end,
           m.joined_at,
           coalesce(p.display_name, ''), p.handle, p.avatar_path,
           (o.signer_user_id = m.user_id)
      from public.memberships m
      join public.organizations o on o.id = m.organization_id
      left join public.creator_profiles p on p.id = m.user_id and p.kind = 'person'
     where m.organization_id = p_org and m.removed_at is null
     order by case m.role when 'owner' then 0 when 'admin' then 1 when 'manager' then 2 when 'creator' then 3 else 4 end,
              lower(coalesce(p.display_name, '')), m.user_id;
end;
$$;

-- The people a client may book, for the public company page.
create or replace function public.org_public_team(p_org uuid)
returns table (user_id uuid, display_name text, handle text, avatar_path text, bio text, specialties text[], title text)
language sql
stable
security definer
set search_path = public
as $$
  select m.user_id, p.display_name, p.handle, p.avatar_path, p.bio, p.specialties, m.title
    from public.memberships m
    join public.organizations o on o.id = m.organization_id and o.state = 'active'
    join public.creator_profiles p on p.id = m.user_id and p.kind = 'person'
   where m.organization_id = p_org and m.removed_at is null and m.listed and m.bookable
   order by case m.role when 'owner' then 0 when 'admin' then 1 when 'manager' then 2 else 3 end, lower(p.display_name), m.user_id;
$$;

-- ---------------------------------------------------------------------------
-- Creating a company
-- ---------------------------------------------------------------------------
-- A person's own profile is needed as their member sub-profile; make a minimal one if they have none.
create or replace function public.ensure_person_profile(p_user uuid, p_display_name text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name   text := btrim(coalesce(p_display_name, ''));
  v_base   text;
  v_handle text;
  v_try    integer := 0;
begin
  if exists (select 1 from public.creator_profiles where id = p_user) then
    return;
  end if;
  if char_length(v_name) not between 1 and 80 then
    raise exception 'profile_required';
  end if;
  v_base := btrim(regexp_replace(lower(v_name), '[^a-z0-9]+', '-', 'g'), '-');
  v_base := btrim(left(v_base, 20), '-');
  if char_length(v_base) < 2 then
    v_base := 'member';
  end if;
  loop
    v_handle := v_base || '-' || substr(md5(random()::text || clock_timestamp()::text), 1, 5);
    exit when not exists (select 1 from public.creator_profiles where handle = v_handle);
    v_try := v_try + 1;
    exit when v_try > 20;
  end loop;
  insert into public.creator_profiles (id, handle, display_name) values (p_user, v_handle, v_name);
end;
$$;

create or replace function public.org_create(
  p_handle              text,
  p_display_name        text,
  p_legal_name          text,
  p_legal_address       text default '',
  p_bio                 text default '',
  p_specialties         text[] default '{}',
  p_location_name       text default null,
  p_owner_display_name  text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
  v_id  uuid := gen_random_uuid();
begin
  perform public.ensure_person_profile(v_uid, p_owner_display_name);

  begin
    insert into public.creator_profiles (id, kind, handle, display_name, bio, specialties, location_name)
    values (v_id, 'company', lower(btrim(p_handle)), btrim(p_display_name), coalesce(p_bio, ''),
            coalesce(p_specialties, '{}'), nullif(btrim(coalesce(p_location_name, '')), ''));
  exception
    when unique_violation then
      raise exception 'handle_taken';
    when check_violation then
      raise exception 'invalid_input';
  end;

  insert into public.organizations (id, legal_name, legal_address, created_by)
  values (v_id, btrim(p_legal_name), btrim(coalesce(p_legal_address, '')), v_uid);

  insert into public.memberships (organization_id, user_id, role) values (v_id, v_uid, 'owner');

  perform public.activity_add(v_id, 'org.created', 'company', v_id,
    'Created ' || btrim(p_display_name));
  return public.org_overview(v_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Company settings
-- ---------------------------------------------------------------------------
create or replace function public.org_update(
  p_org             uuid,
  p_legal_name      text default null,
  p_legal_address   text default null,
  p_assignment_mode text default null,
  p_signer_roles    text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := public.require_user();
  v_org  public.organizations;
  v_new  public.organizations;
  v_what text[] := '{}';
begin
  select * into v_org from public.organizations where id = p_org for update;
  if not found or public.org_role_of(v_uid, p_org) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'company.edit') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_assignment_mode is not null and p_assignment_mode not in ('auto', 'manual') then
    raise exception 'invalid_input';
  end if;
  -- Widening who may sign for the company is the Owner's call.
  if p_signer_roles is not null and p_signer_roles is distinct from v_org.signer_roles
     and public.org_role_of(v_uid, p_org) <> 'owner' then
    raise exception 'not_allowed' using errcode = '42501';
  end if;

  begin
    update public.organizations
       set legal_name = coalesce(nullif(btrim(p_legal_name), ''), legal_name),
           legal_address = coalesce(btrim(p_legal_address), legal_address),
           assignment_mode = coalesce(p_assignment_mode, assignment_mode),
           signer_roles = coalesce(p_signer_roles, signer_roles)
     where id = p_org
    returning * into v_new;
  exception
    when check_violation then
      raise exception 'invalid_input';
  end;

  if v_new.legal_name is distinct from v_org.legal_name then v_what := array_append(v_what, 'legal name'); end if;
  if v_new.legal_address is distinct from v_org.legal_address then v_what := array_append(v_what, 'legal address'); end if;
  if v_new.assignment_mode is distinct from v_org.assignment_mode then
    v_what := array_append(v_what, ('assignment: ' || v_new.assignment_mode));
  end if;
  if v_new.signer_roles is distinct from v_org.signer_roles then v_what := array_append(v_what, 'signer roles'); end if;
  if cardinality(v_what) > 0 then
    perform public.activity_add(p_org, 'org.updated', 'company', p_org,
      'Changed company settings (' || array_to_string(v_what, ', ') || ')');
  end if;
  perform public.org_revalidate_signer(p_org);
  return public.org_overview(p_org);
end;
$$;

create or replace function public.org_set_split(p_org uuid, p_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
begin
  if public.org_role_of(v_uid, p_org) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'payouts.split') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  update public.organizations set split_enabled = coalesce(p_enabled, false)
   where id = p_org and split_enabled is distinct from coalesce(p_enabled, false);
  if found then
    perform public.activity_add(p_org, 'org.split_changed', 'company', p_org,
      case when p_enabled then 'Turned on the member split ledger' else 'Turned off the member split ledger' end);
  end if;
  return public.org_overview(p_org);
end;
$$;

-- Names who countersigns company contracts. The signer needs a stored signature of their own and a role the company
-- allows. Designating applies to new contracts only.
create or replace function public.org_designate_signer(p_org uuid, p_user uuid, p_title text default '')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := public.require_user();
  v_org  public.organizations;
  v_role text;
begin
  select * into v_org from public.organizations where id = p_org for update;
  if not found or public.org_role_of(v_uid, p_org) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'signer.designate') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  v_role := public.org_role_of(p_user, p_org);
  if v_role is null then
    raise exception 'not_found';
  end if;
  if not (v_role = any (v_org.signer_roles)) then
    raise exception 'signer_role_not_allowed';
  end if;
  if not exists (select 1 from public.creator_signatures where creator_id = p_user) then
    raise exception 'signature_required';
  end if;
  if char_length(coalesce(p_title, '')) > 80 then
    raise exception 'invalid_input';
  end if;

  update public.organizations
     set signer_user_id = p_user, signer_title = btrim(coalesce(p_title, '')),
         signer_designated_by = v_uid, signer_authorized_at = now()
   where id = p_org;
  perform public.activity_add(p_org, 'signer.designated', 'company', p_org,
    'Named ' || coalesce(nullif(public.person_name(p_user), ''), 'a member') || ' as the signer for company contracts');
  return public.org_overview(p_org);
end;
$$;

-- ---------------------------------------------------------------------------
-- Invites
-- ---------------------------------------------------------------------------
create or replace function public.invite_hash(p_token text)
returns text
language sql
immutable
as $$
  select encode(extensions.digest(convert_to(coalesce(p_token, ''), 'UTF8'), 'sha256'), 'hex');
$$;

-- Makes an invite and returns its token, once.
create or replace function public.invite_create(p_org uuid, p_role text, p_email text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := public.require_user();
  v_actor  text := public.org_role_of(v_uid, p_org);
  v_email  text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_token  text;
  v_invite public.invites;
  v_seats  jsonb;
begin
  if v_actor is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'team.invite') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_role not in ('admin', 'manager', 'creator', 'viewer') then
    raise exception 'invalid_role';
  end if;
  if not public.org_can_assign_role(v_actor, 'viewer', p_role) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_email is not null and (char_length(v_email) > 254 or v_email not like '%_@_%') then
    raise exception 'invalid_input';
  end if;
  if not public.org_can_grow(p_org) then
    raise exception 'plan_inactive';
  end if;

  -- Serialise seat checks for one company so two invites can't both take the last seat.
  perform 1 from public.organizations where id = p_org for update;
  v_seats := public.org_seat_counts(p_org);
  if (v_seats ->> 'used')::integer + (v_seats ->> 'pending')::integer >= (v_seats ->> 'maximum')::integer then
    raise exception 'seat_limit';
  end if;

  v_token := translate(encode(extensions.gen_random_bytes(24), 'base64'), '+/=', '-_');
  insert into public.invites (organization_id, role, email, token_hash, invited_by, expires_at)
  values (p_org, p_role, v_email, public.invite_hash(v_token), v_uid, now() + make_interval(days => public.app_invite_days()))
  returning * into v_invite;

  perform public.activity_add(p_org, 'invite.created', 'invite', v_invite.id,
    'Invited ' || coalesce(v_email, 'someone') || ' as ' || p_role,
    jsonb_build_object('role', p_role));
  return jsonb_build_object(
    'invite', jsonb_build_object('id', v_invite.id, 'organization_id', p_org, 'role', v_invite.role, 'email', v_invite.email,
                                 'expires_at', v_invite.expires_at, 'created_at', v_invite.created_at, 'status', 'pending'),
    'token', v_token
  );
end;
$$;

create or replace function public.invite_list(p_org uuid)
returns table (id uuid, role text, email text, status text, created_at timestamptz, expires_at timestamptz, invited_by_name text)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public.require_user();
  if public.org_role_of(auth.uid(), p_org) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'team.invite') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return query
    select i.id, i.role, i.email,
           case when i.status = 'pending' and i.expires_at <= now() then 'expired' else i.status end,
           i.created_at, i.expires_at, public.person_name(i.invited_by)
      from public.invites i
     where i.organization_id = p_org and i.status = 'pending'
     order by i.created_at desc, i.id;
end;
$$;

create or replace function public.invite_revoke(p_invite_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := public.require_user();
  v_invite public.invites;
begin
  select * into v_invite from public.invites where id = p_invite_id for update;
  if not found or public.org_role_of(v_uid, v_invite.organization_id) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(v_invite.organization_id, 'team.invite') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  -- An Admin can't cancel an invite that would have made an Admin.
  if not public.org_can_assign_role(public.org_role_of(v_uid, v_invite.organization_id), 'viewer', v_invite.role) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_invite.status <> 'pending' then
    raise exception 'invite_invalid';
  end if;
  update public.invites set status = 'revoked' where id = p_invite_id;
  perform public.activity_add(v_invite.organization_id, 'invite.revoked', 'invite', p_invite_id,
    'Cancelled the invite for ' || coalesce(v_invite.email, 'someone'));
end;
$$;

-- A lost link is replaced, not recovered: the old invite is revoked and a new one made with the same role and email.
create or replace function public.invite_resend(p_invite_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_invite public.invites;
begin
  select * into v_invite from public.invites where id = p_invite_id;
  if not found then
    raise exception 'not_found';
  end if;
  perform public.invite_revoke(p_invite_id);
  return public.invite_create(v_invite.organization_id, v_invite.role, v_invite.email);
end;
$$;

-- What the person who opened the link sees before joining. One error for every bad token, so it can't be probed.
create or replace function public.invite_preview(p_token text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid    uuid := public.require_user();
  v_invite public.invites;
  v_name   text;
begin
  select * into v_invite from public.invites where token_hash = public.invite_hash(p_token);
  if not found or v_invite.status <> 'pending' or v_invite.expires_at <= now()
     or not exists (select 1 from public.organizations o where o.id = v_invite.organization_id and o.state = 'active') then
    raise exception 'invite_invalid';
  end if;
  select display_name into v_name from public.creator_profiles where id = v_invite.organization_id;
  return jsonb_build_object(
    'organization_id', v_invite.organization_id,
    'organization_name', v_name,
    'role', v_invite.role,
    'invited_by_name', public.person_name(v_invite.invited_by),
    'expires_at', v_invite.expires_at,
    'already_member', public.org_role_of(v_uid, v_invite.organization_id) is not null,
    'has_profile', exists (select 1 from public.creator_profiles where id = v_uid and kind = 'person')
  );
end;
$$;

create or replace function public.accept_invite(p_token text, p_display_name text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := public.require_user();
  v_invite public.invites;
  v_name   text;
begin
  select * into v_invite from public.invites where token_hash = public.invite_hash(p_token) for update;
  if not found or v_invite.status <> 'pending' or v_invite.expires_at <= now()
     or not exists (select 1 from public.organizations o where o.id = v_invite.organization_id and o.state = 'active') then
    raise exception 'invite_invalid';
  end if;
  if public.org_role_of(v_uid, v_invite.organization_id) is not null then
    raise exception 'already_member';
  end if;

  perform public.ensure_person_profile(v_uid, p_display_name);

  begin
    insert into public.memberships (organization_id, user_id, role, bookable)
    values (v_invite.organization_id, v_uid, v_invite.role, v_invite.role <> 'viewer');
  exception
    when unique_violation then
      raise exception 'already_member';
  end;

  update public.invites set status = 'accepted', accepted_by = v_uid, accepted_at = now() where id = v_invite.id;

  v_name := coalesce(nullif(public.person_name(v_uid), ''), 'Someone');
  perform public.activity_add(v_invite.organization_id, 'member.joined', 'member', v_uid,
    v_name || ' joined as ' || v_invite.role, jsonb_build_object('role', v_invite.role));
  return public.org_overview(v_invite.organization_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Members
-- ---------------------------------------------------------------------------
create or replace function public.member_set_role(p_org uuid, p_user uuid, p_role text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := public.require_user();
  v_actor   text := public.org_role_of(v_uid, p_org);
  v_current text := public.org_role_of(p_user, p_org);
begin
  if v_actor is null or v_current is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'team.manage') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_role not in ('admin', 'manager', 'creator', 'viewer') then
    raise exception 'invalid_role';
  end if;
  if p_user = v_uid or not public.org_can_assign_role(v_actor, v_current, p_role) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_current = p_role then
    return;
  end if;

  update public.memberships
     set role = p_role,
         bookable = case when p_role = 'viewer' then false when v_current = 'viewer' then true else bookable end
   where organization_id = p_org and user_id = p_user and removed_at is null;
  perform public.activity_add(p_org, 'member.role_changed', 'member', p_user,
    'Changed ' || coalesce(nullif(public.person_name(p_user), ''), 'a member') || ' from ' || v_current || ' to ' || p_role,
    jsonb_build_object('from', v_current, 'to', p_role));
  perform public.org_revalidate_signer(p_org);
end;
$$;

-- Title, whether they are on the company page, and whether clients can book them.
create or replace function public.member_update(
  p_org      uuid,
  p_user     uuid,
  p_title    text default null,
  p_listed   boolean default null,
  p_bookable boolean default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := public.require_user();
  v_actor   text := public.org_role_of(v_uid, p_org);
  v_current text := public.org_role_of(p_user, p_org);
begin
  if v_actor is null or v_current is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'team.manage') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  -- You may edit yourself or anyone you could manage.
  if p_user <> v_uid and not public.org_can_manage_role(v_actor, v_current) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_bookable and v_current = 'viewer' then
    raise exception 'invalid_input';
  end if;
  if p_title is not null and char_length(btrim(p_title)) > 80 then
    raise exception 'invalid_input';
  end if;

  update public.memberships
     set title = coalesce(btrim(p_title), title),
         listed = coalesce(p_listed, listed),
         bookable = coalesce(p_bookable, bookable)
   where organization_id = p_org and user_id = p_user and removed_at is null;
  perform public.activity_add(p_org, 'member.updated', 'member', p_user,
    'Updated ' || coalesce(nullif(public.person_name(p_user), ''), 'a member') || '''s team profile');
end;
$$;

create or replace function public.member_set_share(p_org uuid, p_user uuid, p_share_bps integer)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
begin
  if public.org_role_of(v_uid, p_org) is null or public.org_role_of(p_user, p_org) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'payouts.split') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_share_bps is null or p_share_bps not between 0 and 10000 then
    raise exception 'invalid_input';
  end if;
  update public.memberships set share_bps = p_share_bps
   where organization_id = p_org and user_id = p_user and removed_at is null;
  perform public.activity_add(p_org, 'member.share_changed', 'member', p_user,
    'Set ' || coalesce(nullif(public.person_name(p_user), ''), 'a member') || '''s share to '
    || trim(to_char(p_share_bps / 100.0, 'FM990.00')) || '%',
    jsonb_build_object('share_bps', p_share_bps));
end;
$$;

-- Ends a membership. Part 2 returns the person's future bookings to the assignment queue from the trigger below.
create or replace function public.member_end(p_org uuid, p_user uuid, p_action text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
begin
  update public.memberships
     set removed_at = now(), removed_by = v_uid
   where organization_id = p_org and user_id = p_user and removed_at is null;
  perform public.activity_add(p_org, p_action, 'member', p_user,
    case p_action when 'member.left' then coalesce(nullif(public.person_name(p_user), ''), 'A member') || ' left the team'
                  else 'Removed ' || coalesce(nullif(public.person_name(p_user), ''), 'a member') || ' from the team' end);
  perform public.org_revalidate_signer(p_org);
end;
$$;

create or replace function public.member_remove(p_org uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := public.require_user();
  v_actor   text := public.org_role_of(v_uid, p_org);
  v_current text := public.org_role_of(p_user, p_org);
begin
  if v_actor is null or v_current is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'team.manage') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if v_current = 'owner' then
    raise exception 'last_owner';
  end if;
  if p_user = v_uid or not public.org_can_manage_role(v_actor, v_current) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  perform public.member_end(p_org, p_user, 'member.removed');
end;
$$;

create or replace function public.member_leave(p_org uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := public.require_user();
  v_role text := public.org_role_of(v_uid, p_org);
begin
  if v_role is null then
    raise exception 'not_found';
  end if;
  if v_role = 'owner' then
    raise exception 'last_owner';
  end if;
  perform public.member_end(p_org, v_uid, 'member.left');
end;
$$;

-- The Owner hands the company to another member, and becomes an Admin.
create or replace function public.org_transfer_ownership(p_org uuid, p_to_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
begin
  perform 1 from public.organizations where id = p_org for update;
  if public.org_role_of(v_uid, p_org) is distinct from 'owner' then
    if public.org_role_of(v_uid, p_org) is null then
      raise exception 'not_found';
    end if;
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if p_to_user = v_uid or public.org_role_of(p_to_user, p_org) is null then
    raise exception 'invalid_input';
  end if;

  -- The one-owner index is checked after each statement, so demote first and then promote.
  update public.memberships set role = 'admin' where organization_id = p_org and user_id = v_uid and removed_at is null;
  update public.memberships set role = 'owner', bookable = true
   where organization_id = p_org and user_id = p_to_user and removed_at is null;
  perform public.activity_add(p_org, 'org.ownership_transferred', 'company', p_org,
    'Transferred ownership to ' || coalesce(nullif(public.person_name(p_to_user), ''), 'a member'));
  perform public.org_revalidate_signer(p_org);
end;
$$;

-- Deleting a company closes it. Its contracts and activity log are kept, because signed contracts name it.
create or replace function public.org_close(p_org uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
begin
  perform 1 from public.organizations where id = p_org for update;
  if public.org_role_of(v_uid, p_org) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'company.delete') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if exists (
    select 1 from public.bookings b
     where b.creator_id = p_org and b.status in ('held', 'confirmed') and b.end_at > now()
  ) then
    raise exception 'has_upcoming_bookings';
  end if;

  perform public.activity_add(p_org, 'org.closed', 'company', p_org, 'Closed the company');
  update public.packages set is_published = false where creator_id = p_org;
  update public.memberships set removed_at = now(), removed_by = v_uid where organization_id = p_org and removed_at is null;
  update public.invites set status = 'revoked' where organization_id = p_org and status = 'pending';
  update public.organizations
     set state = 'closed', closed_at = now(), signer_user_id = null, signer_title = '', signer_designated_by = null,
         signer_authorized_at = null
   where id = p_org;
  -- Free the handle for someone else. The profile row stays, because bookings and contracts reference it.
  update public.creator_profiles set handle = 'closed-' || substr(replace(p_org::text, '-', ''), 1, 8) where id = p_org;
end;
$$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
-- Helpers that only other functions use are closed to the API roles.
revoke execute on function
  public.app_setting_int(text, text, integer),
  public.org_perm_for(uuid, uuid, text),
  public.org_role_of(uuid, uuid),
  public.activity_add(uuid, text, text, uuid, text, jsonb),
  public.activity_log_append_only(),
  public.creator_profiles_guard(),
  public.creator_profiles_log_company_edit(),
  public.person_name(uuid),
  public.org_seat_counts(uuid),
  public.org_can_grow(uuid),
  public.org_revalidate_signer(uuid),
  public.ensure_person_profile(uuid, text),
  public.invite_hash(text),
  public.member_end(uuid, uuid, text),
  public.require_user()
from public, anon, authenticated;

-- Policies call these, so the API roles must be able to execute them. They answer only about the caller.
grant execute on function
  public.acts_for(uuid, text),
  public.is_org_member(uuid),
  public.can_use_storage_folder(text),
  public.org_role_allows(text, text),
  public.org_can_assign_role(text, text, text),
  public.org_can_manage_role(text, text),
  public.team_config(),
  public.app_seat_minimum(),
  public.app_seat_maximum(),
  public.app_invite_days(),
  public.app_grace_days()
to anon, authenticated;

revoke execute on function
  public.my_accounts(), public.org_overview(uuid), public.org_seats(uuid), public.member_list(uuid),
  public.activity_list(uuid, integer, timestamptz),
  public.org_create(text, text, text, text, text, text[], text, text),
  public.org_update(uuid, text, text, text, text[]),
  public.org_set_split(uuid, boolean),
  public.org_designate_signer(uuid, uuid, text),
  public.invite_create(uuid, text, text), public.invite_list(uuid), public.invite_revoke(uuid), public.invite_resend(uuid),
  public.invite_preview(text), public.accept_invite(text, text),
  public.member_set_role(uuid, uuid, text), public.member_update(uuid, uuid, text, boolean, boolean),
  public.member_set_share(uuid, uuid, integer), public.member_remove(uuid, uuid), public.member_leave(uuid),
  public.org_transfer_ownership(uuid, uuid), public.org_close(uuid)
from public, anon;

grant execute on function
  public.my_accounts(), public.org_overview(uuid), public.org_seats(uuid), public.member_list(uuid),
  public.activity_list(uuid, integer, timestamptz),
  public.org_create(text, text, text, text, text, text[], text, text),
  public.org_update(uuid, text, text, text, text[]),
  public.org_set_split(uuid, boolean),
  public.org_designate_signer(uuid, uuid, text),
  public.invite_create(uuid, text, text), public.invite_list(uuid), public.invite_revoke(uuid), public.invite_resend(uuid),
  public.invite_preview(text), public.accept_invite(text, text),
  public.member_set_role(uuid, uuid, text), public.member_update(uuid, uuid, text, boolean, boolean),
  public.member_set_share(uuid, uuid, integer), public.member_remove(uuid, uuid), public.member_leave(uuid),
  public.org_transfer_ownership(uuid, uuid), public.org_close(uuid)
to authenticated;

-- The public company page.
grant execute on function public.org_public_team(uuid) to anon, authenticated;
