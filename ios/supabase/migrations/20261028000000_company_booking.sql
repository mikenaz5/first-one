-- Company accounts, part 2: services, bookings, contracts, payments and conversations owned by a company.
--
-- Part 1 made a company a creator_profiles row (kind = 'company') with members and roles. This part lets that row own
-- the things a creator owns, and rewires every place that said "the creator is the signed-in user" to ask the
-- database who may act for the owner (acts_for) and what they may do with a booking (provider_access).
--
--   * packages, templates and availability belong to the company; its Owner and Admins edit them.
--   * a booking is owned by the company (creator_id) and *assigned* to one person (assigned_to). Nobody is ever in
--     two places: the exclusion constraint is on the assigned person, so a company's members work in parallel and
--     a person's personal and company bookings still can't overlap.
--   * a contract names the company and is countersigned by the designated signer, who is fixed when the client signs.
--   * payments go to the company's own Stripe Connect account (creator_payment_accounts keyed by the company).
--   * what a person on the provider side can see or do with a booking depends on their role (provider_access).
--
-- Nothing here changes what a person who sells alone experiences. Their profile is their own owner, assigned_to is
-- always themselves, and every function falls back to the old behaviour for them.

-- ---------------------------------------------------------------------------
-- Who is on the provider side of a booking
-- ---------------------------------------------------------------------------
-- 'view' reads a booking; 'manage' acts on it (cancel, deliver, message). A person owner can do both. In a company
-- the Owner, Admins and Managers can manage any booking, Viewers can read any, and a Creator works on the
-- bookings assigned to them.
create or replace function public.provider_access(p_user uuid, p_creator uuid, p_assigned uuid, p_level text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_user is not null and (
    p_user = p_creator
    or case p_level
         when 'manage' then public.org_perm_for(p_user, p_creator, 'bookings.manage')
                            or (p_assigned = p_user and public.org_perm_for(p_user, p_creator, 'bookings.manage_assigned'))
         else public.org_perm_for(p_user, p_creator, 'bookings.view_all')
              or (p_assigned = p_user and public.org_perm_for(p_user, p_creator, 'bookings.manage_assigned'))
       end
  );
$$;

-- The same for the signed-in user, for policies and for the functions the app calls.
create or replace function public.provider_view(p_creator uuid, p_assigned uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select public.provider_access(auth.uid(), p_creator, p_assigned, 'view') $$;

create or replace function public.provider_manage(p_creator uuid, p_assigned uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select public.provider_access(auth.uid(), p_creator, p_assigned, 'manage') $$;

-- Who hears about a booking on the provider side: a person's own notifications, a company's assigned member, or
-- (while nobody is assigned) everyone who can assign it.
create or replace function public.provider_recipients(p_creator uuid, p_assigned uuid)
returns setof uuid
language sql
stable
security definer
set search_path = public
as $$
  select p.id from public.creator_profiles p where p.id = p_creator and p.kind = 'person'
  union
  select m.user_id from public.memberships m
   where m.organization_id = p_creator and m.removed_at is null and p_assigned is not null and m.user_id = p_assigned
  union
  select m.user_id from public.memberships m
   where m.organization_id = p_creator and m.removed_at is null and p_assigned is null
     and public.org_role_allows(m.role, 'bookings.assign');
$$;

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
-- A member's own hours at the company. Null means "the company's hours". Their hours can only narrow the company's.
alter table public.memberships
  add column weekly jsonb check (weekly is null or (jsonb_typeof(weekly) = 'array' and jsonb_array_length(weekly) <= 7));

-- Who a booking is assigned to. Always set for a person's own bookings; null for a company booking waiting for a Manager.
alter table public.bookings
  add column assigned_to uuid references auth.users (id) on delete set null,
  add column assigned_at timestamptz,
  -- The client asked for this person (a booking made from their card on the company page).
  add column requested_member boolean not null default false,
  -- This person's share of the booking in basis points, if the company keeps a split ledger. A snapshot at assignment.
  add column assignee_share_bps integer check (assignee_share_bps between 0 and 10000);

update public.bookings set assigned_to = creator_id, assigned_at = created_at;

-- Double-booking is about people, not owners.
alter table public.bookings drop constraint bookings_no_overlap;
alter table public.bookings
  add constraint bookings_no_double_booking exclude using gist (
    assigned_to with =,
    tstzrange(start_at, blocked_until, '[)') with &&
  ) where (status in ('held', 'confirmed') and assigned_to is not null);

create index bookings_assigned_start_idx on public.bookings (assigned_to, start_at);
create index bookings_unassigned_idx on public.bookings (creator_id, start_at) where assigned_to is null;

-- A person's bookings are theirs; a company's go to a member who can take them.
create or replace function public.bookings_assignee_guard()
returns trigger
language plpgsql
as $$
declare
  v_company boolean;
begin
  select exists (select 1 from public.organizations o where o.id = new.creator_id) into v_company;
  if not v_company then
    new.assigned_to := new.creator_id;
    return new;
  end if;
  if new.assigned_to is not null
     and (tg_op = 'INSERT' or new.assigned_to is distinct from old.assigned_to)
     and not exists (
       select 1 from public.memberships m
        where m.organization_id = new.creator_id and m.user_id = new.assigned_to
          and m.removed_at is null and m.bookable and m.role <> 'viewer'
     ) then
    raise exception 'invalid_assignee';
  end if;
  return new;
end;
$$;

create trigger bookings_assignee_guard
  before insert or update of assigned_to, creator_id on public.bookings
  for each row execute function public.bookings_assignee_guard();

-- Some packages are offered by chosen people only. No rows means everyone who is bookable.
create table public.package_members (
  package_id uuid not null references public.packages (id) on delete cascade,
  user_id    uuid not null references auth.users (id) on delete cascade,
  primary key (package_id, user_id)
);
create index package_members_user_idx on public.package_members (user_id);
alter table public.package_members enable row level security;

create policy "Package offers are as visible as the package"
  on public.package_members for select
  using (exists (
    select 1 from public.packages p
     where p.id = package_id and (p.is_published or public.acts_for(p.creator_id, 'team.view'))
  ));

-- The countersigner is fixed when the client signs: removing or changing the designated signer later never stops a
-- contract the client already signed from being completed, and never signs one in a name that wasn't authorised then.
alter table public.contracts
  add column countersigner_id    uuid references auth.users (id) on delete set null,
  add column countersigner_name  text,
  add column countersigner_title text,
  add column provider_legal_name text;

alter table public.contract_signatures
  add column on_behalf_of  text,
  add column signer_title  text;

-- ---------------------------------------------------------------------------
-- Policies: services, templates, availability, payment accounts
-- ---------------------------------------------------------------------------
drop policy "Published packages are public; creators see their own" on public.packages;
drop policy "Creators add their own packages" on public.packages;
drop policy "Creators edit their own packages" on public.packages;
drop policy "Creators delete their own packages" on public.packages;

create policy "Published packages are public; the team sees its own"
  on public.packages for select
  using (is_published or public.acts_for(creator_id, 'team.view'));

create policy "Owners add packages"
  on public.packages for insert
  to authenticated
  with check (public.acts_for(creator_id, 'services.manage'));

create policy "Owners edit packages"
  on public.packages for update
  to authenticated
  using (public.acts_for(creator_id, 'services.manage'))
  with check (public.acts_for(creator_id, 'services.manage'));

create policy "Owners delete packages"
  on public.packages for delete
  to authenticated
  using (public.acts_for(creator_id, 'services.manage'));

drop policy "Creators add their own availability" on public.availability_settings;
drop policy "Creators edit their own availability" on public.availability_settings;
drop policy "Creators delete their own availability" on public.availability_settings;

create policy "Owners add availability"
  on public.availability_settings for insert
  to authenticated
  with check (public.acts_for(creator_id, 'company.edit'));

create policy "Owners edit availability"
  on public.availability_settings for update
  to authenticated
  using (public.acts_for(creator_id, 'company.edit'))
  with check (public.acts_for(creator_id, 'company.edit'));

create policy "Owners delete availability"
  on public.availability_settings for delete
  to authenticated
  using (public.acts_for(creator_id, 'company.edit'));

drop policy "Creators read their own contracts" on public.contract_templates;
drop policy "Creators add their own contracts" on public.contract_templates;
drop policy "Creators edit their own contracts" on public.contract_templates;
drop policy "Creators delete their own contracts" on public.contract_templates;

create policy "The team reads its contract templates"
  on public.contract_templates for select
  to authenticated
  using (public.acts_for(creator_id, 'team.view'));

create policy "Owners add contract templates"
  on public.contract_templates for insert
  to authenticated
  with check (public.acts_for(creator_id, 'templates.manage'));

create policy "Owners edit contract templates"
  on public.contract_templates for update
  to authenticated
  using (public.acts_for(creator_id, 'templates.manage'))
  with check (public.acts_for(creator_id, 'templates.manage'));

create policy "Owners delete contract templates"
  on public.contract_templates for delete
  to authenticated
  using (public.acts_for(creator_id, 'templates.manage'));

-- A template's owner never changes, except while a person's services move into the company they just made (or back).
create or replace function public.validate_contract_template()
returns trigger
language plpgsql
as $$
declare
  v_clause jsonb;
  v_tokens text[] := public.contract_tokens(new.title);
  v_token text;
  v_field text;
begin
  if char_length(btrim(new.title)) not between 2 and 80 then
    raise exception 'invalid_contract: title';
  end if;
  if jsonb_typeof(new.clauses) <> 'array' or jsonb_array_length(new.clauses) not between 1 and 30 then
    raise exception 'invalid_contract: sections';
  end if;

  for v_clause in select value from jsonb_array_elements(new.clauses) loop
    if jsonb_typeof(v_clause) <> 'object'
       or jsonb_typeof(v_clause -> 'title') <> 'string'
       or jsonb_typeof(v_clause -> 'body') <> 'string'
       or char_length(btrim(v_clause ->> 'title')) not between 1 and 80
       or char_length(btrim(v_clause ->> 'body')) = 0
       or char_length(v_clause ->> 'body') > 3000 then
      raise exception 'invalid_contract: section';
    end if;
    v_tokens := v_tokens || public.contract_tokens(v_clause ->> 'title') || public.contract_tokens(v_clause ->> 'body');
  end loop;

  foreach v_token in array v_tokens loop
    if not (v_token = any (public.contract_known_fields())) then
      raise exception 'invalid_contract: unknown field %', v_token;
    end if;
  end loop;
  foreach v_field in array public.contract_required_fields() loop
    if not (v_field = any (v_tokens)) then
      raise exception 'invalid_contract: missing field %', v_field;
    end if;
  end loop;

  if tg_op = 'INSERT' then
    if (select count(*) from public.contract_templates where creator_id = new.creator_id) >= 20 then
      raise exception 'invalid_contract: too many contracts';
    end if;
    new.version := 1;
  else
    if coalesce(current_setting('slate.moving_services', true), '') <> 'on' then
      new.creator_id := old.creator_id;
    end if;
    new.created_at := old.created_at;
    if new.title is distinct from old.title or new.clauses is distinct from old.clauses then
      new.version := old.version + 1;
      new.updated_at := now();
    else
      new.version := old.version;
      new.updated_at := old.updated_at;
    end if;
  end if;
  return new;
end;
$$;

drop policy "Creators read their own payment account" on public.creator_payment_accounts;
create policy "Owners read their payment account"
  on public.creator_payment_accounts for select
  to authenticated
  using (public.acts_for(creator_id, 'payments.connect'));

-- The Stripe Connect Edge Function asks this before it opens, reads or creates an account for an owner. A person
-- is their own owner; a company's account is the Owner's to manage.
create or replace function public.connect_authorize(p_user uuid, p_owner uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_user is not null and (p_user = p_owner or public.org_perm_for(p_user, p_owner, 'payments.connect'));
$$;

-- ---------------------------------------------------------------------------
-- Policies: bookings, contracts, payments, conversations
-- ---------------------------------------------------------------------------
drop policy "People see bookings they are part of" on public.bookings;
create policy "People see bookings they are part of"
  on public.bookings for select
  to authenticated
  using ((select auth.uid()) = client_id or public.provider_view(creator_id, assigned_to));

create or replace function public.can_view_contract(p_contract uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.contracts c join public.bookings b on b.id = c.booking_id
     where c.id = p_contract and (auth.uid() = c.client_id or public.provider_view(c.creator_id, b.assigned_to))
  );
$$;

drop policy "Parties read their contract" on public.contracts;
create policy "Parties read their contract"
  on public.contracts for select
  to authenticated
  using (public.can_view_contract(id));

drop policy "Parties read the signatures on their contract" on public.contract_signatures;
create policy "Parties read the signatures on their contract"
  on public.contract_signatures for select
  to authenticated
  using (public.can_view_contract(contract_id));

drop policy "Parties read their signed PDF" on storage.objects;
drop policy "Parties store their signed PDF once" on storage.objects;
create policy "Parties read their signed PDF"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'contracts'
    and exists (select 1 from public.contracts c where c.id::text || '.pdf' = name and public.can_view_contract(c.id))
  );
create policy "Parties store their signed PDF once"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'contracts'
    and exists (select 1 from public.contracts c where c.id::text || '.pdf' = name and public.can_view_contract(c.id))
  );

drop policy "People see the payments on their bookings" on public.payments;
create policy "People see the payments on their bookings"
  on public.payments for select
  to authenticated
  using (exists (
    select 1 from public.bookings b
     where b.id = booking_id
       and ((select auth.uid()) = b.client_id or public.provider_view(b.creator_id, b.assigned_to))
  ));

drop policy "People read the conversation on their bookings" on public.messages;
create policy "People read the conversation on their bookings"
  on public.messages for select
  to authenticated
  using (exists (
    select 1 from public.bookings b
     where b.id = booking_id
       and ((select auth.uid()) = b.client_id or public.provider_view(b.creator_id, b.assigned_to))
  ));

-- Internal, for the Edge Functions: is this user one of the people on the booking?
create or replace function public.is_booking_party(p_user_id uuid, p_booking_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.bookings b
     where b.id = p_booking_id
       and (b.client_id = p_user_id or public.provider_access(p_user_id, b.creator_id, b.assigned_to, 'view'))
  );
$$;

-- ---------------------------------------------------------------------------
-- A member's hours, and what a company is open for
-- ---------------------------------------------------------------------------
-- [{ "weekday": 2, "window": { "startMinute": 540, "endMinute": 1020 } }], at most one window per weekday.
create or replace function public.weekly_valid(p_weekly jsonb)
returns boolean
language sql
immutable
as $$
  select p_weekly is null or (
    jsonb_typeof(p_weekly) = 'array'
    and jsonb_array_length(p_weekly) <= 7
    and not exists (
      select 1 from jsonb_array_elements(p_weekly) e
       where jsonb_typeof(e) <> 'object'
          or (e ->> 'weekday') is null or (e ->> 'weekday') !~ '^[1-7]$'
          or (e -> 'window' ->> 'startMinute') is null or (e -> 'window' ->> 'startMinute') !~ '^[0-9]{1,4}$'
          or (e -> 'window' ->> 'endMinute') is null or (e -> 'window' ->> 'endMinute') !~ '^[0-9]{1,4}$'
          or (e -> 'window' ->> 'startMinute')::integer >= (e -> 'window' ->> 'endMinute')::integer
          or (e -> 'window' ->> 'endMinute')::integer > 1440
    )
    and (select count(distinct e ->> 'weekday') from jsonb_array_elements(p_weekly) e) = jsonb_array_length(p_weekly)
  );
$$;

-- The hours a person is available for the company: its hours, narrowed by their own if they set any.
create or replace function public.effective_weekly(p_company jsonb, p_member jsonb)
returns jsonb
language sql
immutable
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'weekday', c.wd,
           'window', jsonb_build_object('startMinute', greatest(c.s, coalesce(m.s, c.s)), 'endMinute', least(c.e, coalesce(m.e, c.e)))
         ) order by c.wd), '[]'::jsonb)
    from (select (e ->> 'weekday')::integer wd, (e -> 'window' ->> 'startMinute')::integer s, (e -> 'window' ->> 'endMinute')::integer e
            from jsonb_array_elements(coalesce(p_company, '[]'::jsonb)) e) c
    left join (select (e ->> 'weekday')::integer wd, (e -> 'window' ->> 'startMinute')::integer s, (e -> 'window' ->> 'endMinute')::integer e
                 from jsonb_array_elements(coalesce(p_member, '[]'::jsonb)) e) m on m.wd = c.wd
   where (p_member is null or m.wd is not null)
     and greatest(c.s, coalesce(m.s, c.s)) < least(c.e, coalesce(m.e, c.e));
$$;

create or replace function public.member_set_hours(p_org uuid, p_weekly jsonb)
returns void
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
  if not public.acts_for(p_org, 'calendar.manage_own') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if not public.weekly_valid(p_weekly) then
    raise exception 'invalid_input';
  end if;
  update public.memberships set weekly = p_weekly
   where organization_id = p_org and user_id = v_uid and removed_at is null;
end;
$$;

-- Can this person take a booking of this length starting then? 'ok', 'slot_unavailable' (outside their hours or
-- over their calendar) or 'slot_taken' (they already have a booking in that time). A hold that has run out doesn't count.
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

-- The people who can take a package: bookable members, narrowed to the package's chosen few if it has any.
create or replace function public.package_candidates(p_package uuid, p_member uuid default null)
returns table (user_id uuid, joined_at timestamptz, weekly jsonb, upcoming integer)
language sql
stable
security definer
set search_path = public
as $$
  select m.user_id, m.joined_at, m.weekly,
         (select count(*)::integer from public.bookings b
           where b.assigned_to = m.user_id and b.status in ('held', 'confirmed') and b.end_at > now()) as upcoming
    from public.packages p
    join public.memberships m on m.organization_id = p.creator_id
   where p.id = p_package
     and m.removed_at is null and m.bookable and m.role <> 'viewer'
     and (p_member is null or m.user_id = p_member)
     and (not exists (select 1 from public.package_members pm where pm.package_id = p.id)
          or exists (select 1 from public.package_members pm where pm.package_id = p.id and pm.user_id = m.user_id));
$$;

-- ---------------------------------------------------------------------------
-- Contracts under a company's name
-- ---------------------------------------------------------------------------
-- Error tokens: not_signed_in, package_unavailable, cannot_book_yourself, contract_missing, creator_not_ready, slot_unavailable
create or replace function public.contract_prepare(
  p_package_id   uuid,
  p_add_on_ids   uuid[],
  p_start_at     timestamptz,
  p_client_name  text,
  p_notes        text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid           uuid := auth.uid();
  v_requested     uuid[] := coalesce(p_add_on_ids, '{}');
  v_pkg           public.packages;
  v_settings      public.availability_settings;
  v_template      public.contract_templates;
  v_org           public.organizations;
  v_creator_name  text;
  v_provider_name text;
  v_signer        jsonb := null;
  v_add_on        jsonb;
  v_chosen        jsonb := '[]'::jsonb;
  v_found         integer := 0;
  v_values        jsonb;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;

  select * into v_pkg from public.packages where id = p_package_id and is_published;
  if not found then
    raise exception 'package_unavailable';
  end if;
  if v_pkg.creator_id = v_uid or public.org_role_of(v_uid, v_pkg.creator_id) is not null then
    raise exception 'cannot_book_yourself';
  end if;

  select * into v_org from public.organizations where id = v_pkg.creator_id;
  if found and v_org.state <> 'active' then
    raise exception 'package_unavailable';
  end if;

  select * into v_template from public.contract_templates where id = v_pkg.contract_template_id;
  if not found then
    raise exception 'contract_missing';
  end if;

  select display_name into v_creator_name from public.creator_profiles where id = v_pkg.creator_id;
  v_provider_name := coalesce(v_creator_name, 'Creator');
  if v_org.id is not null then
    -- A company's contracts are in its legal name and countersigned by the person it has authorised.
    v_provider_name := v_org.legal_name;
    if v_org.signer_user_id is null or not exists (
         select 1 from public.creator_signatures where creator_id = v_org.signer_user_id)
       or public.org_role_of(v_org.signer_user_id, v_org.id) is null then
      raise exception 'creator_not_ready';
    end if;
    select jsonb_build_object('id', v_org.signer_user_id, 'name', s.signed_name, 'title', v_org.signer_title)
      into v_signer from public.creator_signatures s where s.creator_id = v_org.signer_user_id;
  elsif not exists (select 1 from public.creator_signatures where creator_id = v_pkg.creator_id) then
    raise exception 'creator_not_ready';
  end if;

  select * into v_settings from public.availability_settings where creator_id = v_pkg.creator_id;
  if not found then
    raise exception 'slot_unavailable';
  end if;

  -- Add-ons come from the creator's package, matched by id. The client's own numbers are never used.
  for v_add_on in select value from jsonb_array_elements(v_pkg.add_ons) loop
    if (v_add_on ->> 'id')::uuid = any (v_requested) then
      v_found := v_found + 1;
      v_chosen := v_chosen || jsonb_build_array(v_add_on);
    end if;
  end loop;
  if v_found <> (select count(distinct id) from unnest(v_requested) as id) then
    raise exception 'package_unavailable';
  end if;

  v_values := public.contract_values(v_pkg, v_chosen, p_start_at, v_settings.time_zone, p_client_name, v_provider_name, p_notes);

  return jsonb_build_object(
    'package_id', v_pkg.id,
    'creator_id', v_pkg.creator_id,
    'creator_name', coalesce(v_creator_name, 'Creator'),
    'provider_legal_name', case when v_org.id is not null then v_org.legal_name end,
    'countersigner', v_signer,
    'chosen', v_chosen,
    'rendered', public.contract_render(v_template.title, v_template.clauses, v_values, v_template.id, v_template.version)
  );
end;
$$;

-- Adds the provider's signature and finishes the contract. Used when the deposit is paid (or none is due). A person's
-- is their stored signature; a company's is its designated signer's, as fixed when the client signed.
create or replace function public.contract_execute(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_contract public.contracts;
  v_sig      public.creator_signatures;
begin
  select * into v_contract from public.contracts where booking_id = p_booking_id for update;
  if not found or v_contract.status = 'executed' then
    return;
  end if;

  if v_contract.countersigner_id is not null or v_contract.provider_legal_name is not null then
    select * into v_sig from public.creator_signatures where creator_id = v_contract.countersigner_id;
    insert into public.contract_signatures (contract_id, role, user_id, signed_name, method, image_png, consent_version,
                                            device, ip, on_behalf_of, signer_title)
    values (v_contract.id, 'creator', v_contract.countersigner_id,
            coalesce(v_contract.countersigner_name, v_sig.signed_name, 'Authorised signer'), 'onFile',
            case when v_sig.method = 'drawn' and v_sig.signed_name = v_contract.countersigner_name then v_sig.image_png end,
            1, 'Signature on file, applied for the company when the booking was confirmed', null,
            v_contract.provider_legal_name, nullif(v_contract.countersigner_title, ''))
    on conflict (contract_id, role) do nothing;
  else
    select * into v_sig from public.creator_signatures where creator_id = v_contract.creator_id;
    if not found then
      raise exception 'creator_not_ready';
    end if;
    insert into public.contract_signatures (contract_id, role, user_id, signed_name, method, image_png, consent_version, device, ip)
    values (v_contract.id, 'creator', v_contract.creator_id, v_sig.signed_name, 'onFile',
            case when v_sig.method = 'drawn' then v_sig.image_png end,
            1, 'Signature on file, applied when the booking was confirmed', null)
    on conflict (contract_id, role) do nothing;
  end if;

  update public.contracts set status = 'executed', executed_at = now() where id = v_contract.id;
end;
$$;

-- ---------------------------------------------------------------------------
-- Making a booking
-- ---------------------------------------------------------------------------
-- create_booking v4. The same single step as before; for a company it also chooses (or leaves open) who takes it:
--   * p_member_id set: that person, or an error if they can't.
--   * otherwise, in 'auto' mode: the free, eligible member with the fewest upcoming bookings (ties: who joined first).
--   * in 'manual' mode the booking waits for a Manager, as long as there are still enough free members for every
--     booking waiting at that time.
-- Additional error tokens: slot_taken, slot_unavailable, creator_not_ready, member_unavailable
drop function public.create_booking(uuid, uuid[], timestamptz, text, text, text, jsonb);

create or replace function public.create_booking(
  p_package_id    uuid,
  p_add_on_ids    uuid[],
  p_start_at      timestamptz,
  p_client_name   text,
  p_notes         text,
  p_document_hash text,
  p_signature     jsonb,
  p_member_id     uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid           uuid := auth.uid();
  v_prep          jsonb;
  v_pkg           public.packages;
  v_settings      public.availability_settings;
  v_org           public.organizations;
  v_chosen        jsonb;
  v_extra_minutes integer;
  v_add_on_total  integer;
  v_duration      integer;
  v_total         integer;
  v_deposit       integer;
  v_held          boolean;
  v_end           timestamptz;
  v_blocked_until timestamptz;
  v_local         timestamp;
  v_day           date;
  v_weekday       integer;
  v_start_minute  integer;
  v_end_minute    integer;
  v_win_start     integer;
  v_win_end       integer;
  v_booking       public.bookings;
  v_contract      public.contracts;
  v_rendered      jsonb;
  v_sig_name      text := btrim(coalesce(p_signature ->> 'signedName', ''));
  v_sig_method    text := p_signature ->> 'method';
  v_sig_image     text := p_signature ->> 'imagePng';
  v_ip            text;
  v_assignee      uuid := null;
  v_share         integer := null;
  v_cand          record;
  v_state         text;
  v_saw_taken     boolean := false;
  v_free          integer := 0;
  v_waiting       integer;
  v_lapsed        uuid;
begin
  v_prep := public.contract_prepare(p_package_id, p_add_on_ids, p_start_at, p_client_name, p_notes);
  v_rendered := v_prep -> 'rendered';
  v_chosen := v_prep -> 'chosen';

  perform public.assert_payments_ready(p_package_id);
  -- Holds that lapsed must stop blocking the calendar before we look at it.
  perform public.expire_holds((v_prep ->> 'creator_id')::uuid);

  select * into v_pkg from public.packages where id = p_package_id;
  select * into v_settings from public.availability_settings where creator_id = v_pkg.creator_id;
  select * into v_org from public.organizations where id = v_pkg.creator_id;

  select coalesce(sum(coalesce((e ->> 'extraMinutes')::integer, 0)), 0), coalesce(sum(coalesce((e ->> 'priceCents')::integer, 0)), 0)
    into v_extra_minutes, v_add_on_total
    from jsonb_array_elements(v_chosen) e;

  v_duration := v_pkg.duration_minutes + v_extra_minutes;
  v_end := p_start_at + make_interval(mins => v_duration);
  v_blocked_until := v_end + make_interval(mins => v_settings.buffer_minutes);

  v_local := p_start_at at time zone v_settings.time_zone;
  v_day := v_local::date;
  v_weekday := extract(dow from v_local)::integer + 1;
  v_start_minute := extract(hour from v_local)::integer * 60 + extract(minute from v_local)::integer;
  v_end_minute := v_start_minute + v_duration;

  if extract(second from v_local) <> 0 then
    raise exception 'slot_unavailable';
  end if;
  if p_start_at < now() + make_interval(hours => v_settings.min_notice_hours) then
    raise exception 'slot_unavailable';
  end if;
  if v_day > (now() at time zone v_settings.time_zone)::date + v_settings.max_advance_days then
    raise exception 'slot_unavailable';
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_settings.blackouts) as b
     where v_day between (b ->> 'start')::date and (b ->> 'end')::date
  ) then
    raise exception 'slot_unavailable';
  end if;

  if v_org.id is null then
    -- A person selling alone: their hours and their calendar.
    select (e -> 'window' ->> 'startMinute')::integer, (e -> 'window' ->> 'endMinute')::integer
      into v_win_start, v_win_end
      from jsonb_array_elements(v_settings.weekly) as e
     where (e ->> 'weekday')::integer = v_weekday
     limit 1;
    if v_win_start is null
       or v_start_minute < v_win_start
       or v_end_minute > v_win_end
       or (v_start_minute - v_win_start) % v_settings.slot_interval_minutes <> 0 then
      raise exception 'slot_unavailable';
    end if;

    if exists (
      select 1 from public.busy_blocks bb
       where bb.creator_id = v_pkg.creator_id
         and tstzrange(bb.starts_at, bb.ends_at + make_interval(mins => v_settings.buffer_minutes), '[)')
             && tstzrange(p_start_at, v_blocked_until, '[)')
    ) then
      raise exception 'slot_unavailable';
    end if;
    v_assignee := v_pkg.creator_id;
  else
    -- A company: find the people who could take it, and who is free.
    if p_member_id is not null and not exists (select 1 from public.package_candidates(v_pkg.id, p_member_id)) then
      raise exception 'member_unavailable';
    end if;
    for v_cand in
      select * from public.package_candidates(v_pkg.id, p_member_id) order by upcoming, joined_at, user_id
    loop
      v_state := public.member_slot_state(v_org.id, v_cand.user_id, v_cand.weekly, v_settings, p_start_at, v_end, v_blocked_until);
      if v_state = 'ok' then
        v_free := v_free + 1;
        if v_assignee is null and (p_member_id is not null or v_org.assignment_mode = 'auto') then
          v_assignee := v_cand.user_id;
        end if;
      elsif v_state = 'slot_taken' then
        v_saw_taken := true;
      end if;
    end loop;

    if v_free = 0 then
      raise exception '%', case when v_saw_taken then 'slot_taken' else 'slot_unavailable' end;
    end if;
    if v_assignee is null then
      -- Manual assignment: enough free people for everyone already waiting at that time, and one more.
      select count(*) into v_waiting from public.bookings b
       where b.creator_id = v_org.id and b.assigned_to is null
         and (b.status = 'confirmed' or (b.status = 'held' and b.hold_expires_at > now()))
         and tstzrange(b.start_at, b.blocked_until, '[)') && tstzrange(p_start_at, v_blocked_until, '[)');
      if v_waiting >= v_free then
        raise exception 'slot_taken';
      end if;
    else
      -- The person's own earlier holds that ran out must stop blocking them, then they are locked while we re-check:
      -- company first, then person, always in that order.
      for v_lapsed in
        select distinct b.creator_id from public.bookings b
         where b.assigned_to = v_assignee and b.status = 'held' and b.hold_expires_at <= now()
         order by 1
      loop
        perform public.expire_holds(v_lapsed);
      end loop;
      perform public.lock_creator_calendar(v_assignee);
      select * into v_cand from public.package_candidates(v_pkg.id, v_assignee);
      if not found then
        raise exception 'slot_taken';
      end if;
      if public.member_slot_state(v_org.id, v_assignee, v_cand.weekly, v_settings, p_start_at, v_end, v_blocked_until) <> 'ok' then
        raise exception 'slot_taken';
      end if;
      if v_org.split_enabled then
        select m.share_bps into v_share from public.memberships m
         where m.organization_id = v_org.id and m.user_id = v_assignee and m.removed_at is null;
      end if;
    end if;
  end if;

  if char_length(v_sig_name) not between 2 and 80
     or v_sig_method not in ('typed', 'drawn')
     or (v_sig_method = 'drawn' and (v_sig_image is null or char_length(v_sig_image) > 400000 or char_length(v_sig_image) = 0)) then
    raise exception 'invalid_signature';
  end if;

  if p_document_hash is distinct from (v_rendered ->> 'document_hash') then
    raise exception 'contract_changed';
  end if;

  v_total := v_pkg.price_cents + v_add_on_total;
  v_deposit := least(v_pkg.deposit_cents, v_total);
  v_held := v_deposit > 0;

  begin
    insert into public.bookings (
      creator_id, assigned_to, assigned_at, requested_member, assignee_share_bps,
      client_id, creator_name, client_name, package_id, package_name, add_ons,
      start_at, end_at, blocked_until, time_zone, currency_code, total_cents, deposit_cents,
      status, hold_expires_at, cancellation_policy, notes
    ) values (
      v_pkg.creator_id, v_assignee, case when v_assignee is not null then now() end,
      p_member_id is not null, v_share,
      v_uid, v_prep ->> 'creator_name', left(coalesce(p_client_name, ''), 80),
      v_pkg.id, v_pkg.name,
      coalesce((select jsonb_agg(jsonb_build_object(
          'id', e ->> 'id', 'name', e ->> 'name',
          'priceCents', coalesce((e ->> 'priceCents')::integer, 0),
          'extraMinutes', coalesce((e ->> 'extraMinutes')::integer, 0)))
        from jsonb_array_elements(v_chosen) e), '[]'::jsonb),
      p_start_at, v_end, v_blocked_until, v_settings.time_zone, v_pkg.currency_code, v_total, v_deposit,
      case when v_held then 'held'::public.booking_status else 'confirmed'::public.booking_status end,
      case when v_held then now() + make_interval(mins => public.app_hold_minutes()) end,
      v_pkg.cancellation_policy,
      left(coalesce(p_notes, ''), 500)
    )
    returning * into v_booking;
  exception
    when exclusion_violation then
      raise exception 'slot_taken';
  end;

  v_ip := nullif(btrim(split_part(coalesce(nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-forwarded-for', ''), ',', 1)), '');

  insert into public.contracts (
    booking_id, creator_id, client_id, template_id, template_version, title, sections, document_hash, status, executed_at,
    countersigner_id, countersigner_name, countersigner_title, provider_legal_name
  ) values (
    v_booking.id, v_pkg.creator_id, v_uid, (v_rendered ->> 'template_id')::uuid, (v_rendered ->> 'template_version')::integer,
    v_rendered ->> 'title', v_rendered -> 'sections', v_rendered ->> 'document_hash',
    'pending', null,
    (v_prep -> 'countersigner' ->> 'id')::uuid, v_prep -> 'countersigner' ->> 'name', v_prep -> 'countersigner' ->> 'title',
    v_prep ->> 'provider_legal_name'
  )
  returning * into v_contract;

  insert into public.contract_signatures (contract_id, role, user_id, signed_name, method, image_png, consent_version, device, ip)
  values (v_contract.id, 'client', v_uid, v_sig_name, v_sig_method,
          case when v_sig_method = 'drawn' then v_sig_image end,
          coalesce((p_signature ->> 'consentVersion')::integer, 1), left(coalesce(p_signature ->> 'device', ''), 200), v_ip);

  -- With a deposit the provider's signature is added when it is paid; with none, the contract is complete now.
  if not v_held then
    perform public.contract_execute(v_booking.id);
  end if;

  return jsonb_build_object('booking', to_jsonb(v_booking), 'contract', public.contract_json(v_contract.id));
end;
$$;

-- ---------------------------------------------------------------------------
-- Assigning
-- ---------------------------------------------------------------------------
create or replace function public.assign_booking(p_booking_id uuid, p_user_id uuid)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := public.require_user();
  v_b        public.bookings;
  v_settings public.availability_settings;
  v_cand     record;
  v_share    integer := null;
  v_org      public.organizations;
  v_from     uuid;
  v_lapsed   uuid;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  select * into v_org from public.organizations where id = v_b.creator_id;
  if not found or public.org_role_of(v_uid, v_b.creator_id) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(v_b.creator_id, 'bookings.assign') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;

  -- Same lock order as booking: the company, then the person.
  perform public.expire_holds(v_b.creator_id);
  perform public.lock_creator_calendar(p_user_id);
  select * into v_b from public.bookings where id = p_booking_id for update;
  if v_b.status not in ('held', 'confirmed') or v_b.end_at <= now() then
    raise exception 'not_assignable';
  end if;
  if v_b.assigned_to is not distinct from p_user_id then
    return v_b;
  end if;

  select * into v_cand from public.package_candidates(v_b.package_id, p_user_id);
  if not found then
    -- The package is gone (or never was one); any bookable member will do.
    select m.user_id, m.joined_at, m.weekly, 0 as upcoming into v_cand
      from public.memberships m
     where m.organization_id = v_b.creator_id and m.user_id = p_user_id
       and m.removed_at is null and m.bookable and m.role <> 'viewer'
       and (v_b.package_id is null);
    if not found then
      raise exception 'invalid_assignee';
    end if;
  end if;

  select * into v_settings from public.availability_settings where creator_id = v_b.creator_id;
  for v_lapsed in
    select distinct b.creator_id from public.bookings b
     where b.assigned_to = p_user_id and b.status = 'held' and b.hold_expires_at <= now()
     order by 1
  loop
    perform public.expire_holds(v_lapsed);
  end loop;
  if v_settings.creator_id is not null
     and public.member_slot_state(v_b.creator_id, p_user_id, v_cand.weekly, v_settings, v_b.start_at, v_b.end_at, v_b.blocked_until, v_b.id) <> 'ok' then
    raise exception 'slot_taken';
  end if;

  if v_org.split_enabled then
    select m.share_bps into v_share from public.memberships m
     where m.organization_id = v_b.creator_id and m.user_id = p_user_id and m.removed_at is null;
  end if;
  v_from := v_b.assigned_to;
  begin
    update public.bookings
       set assigned_to = p_user_id, assigned_at = now(), assignee_share_bps = v_share
     where id = p_booking_id
    returning * into v_b;
  exception
    when exclusion_violation then
      raise exception 'slot_taken';
  end;

  perform public.activity_add(v_b.creator_id,
    case when v_from is null then 'booking.assigned' else 'booking.reassigned' end, 'booking', v_b.id,
    case when v_from is null
      then 'Assigned ' || v_b.package_name || ' to ' || coalesce(nullif(public.person_name(p_user_id), ''), 'a member')
      else 'Moved ' || v_b.package_name || ' from ' || coalesce(nullif(public.person_name(v_from), ''), 'a member')
           || ' to ' || coalesce(nullif(public.person_name(p_user_id), ''), 'a member') end,
    jsonb_build_object('to', p_user_id, 'from', v_from));
  perform public.push_enqueue(p_user_id, 'new_booking', v_b.id, jsonb_build_object(
    'bookingId', v_b.id, 'role', 'creator', 'clientName', v_b.client_name, 'packageName', v_b.package_name,
    'startAt', v_b.start_at, 'timeZone', v_b.time_zone, 'pendingDeposit', v_b.status = 'held',
    'depositCents', v_b.deposit_cents, 'currency', v_b.currency_code), 'assigned:' || v_b.id || ':' || p_user_id);
  return v_b;
end;
$$;

-- Bookings waiting for someone. For people who can assign.
create or replace function public.assignment_queue(p_org uuid)
returns setof public.bookings
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
  if not public.acts_for(p_org, 'bookings.assign') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  return query
    select b.* from public.bookings b
     where b.creator_id = p_org and b.assigned_to is null
       and (b.status = 'confirmed' or (b.status = 'held' and b.hold_expires_at > now()))
       and b.end_at > now()
     order by b.start_at, b.id;
end;
$$;

-- Who can a booking go to right now? One row per eligible member, with whether they are free then.
create or replace function public.assignment_options(p_booking_id uuid)
returns table (user_id uuid, display_name text, free boolean, reason text)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_b        public.bookings;
  v_settings public.availability_settings;
begin
  perform public.require_user();
  select * into v_b from public.bookings where id = p_booking_id;
  if not found or public.org_role_of(auth.uid(), v_b.creator_id) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(v_b.creator_id, 'bookings.assign') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  select * into v_settings from public.availability_settings where creator_id = v_b.creator_id;
  return query
    select m.user_id, coalesce(p.display_name, ''),
           (s.state = 'ok'), case s.state when 'ok' then null when 'slot_taken' then 'Already booked' else 'Not available' end
      from public.memberships m
      left join public.creator_profiles p on p.id = m.user_id and p.kind = 'person'
      cross join lateral (
        select case when v_settings.creator_id is null then 'slot_unavailable'
                    else public.member_slot_state(v_b.creator_id, m.user_id, m.weekly, v_settings, v_b.start_at, v_b.end_at, v_b.blocked_until, v_b.id)
               end as state
      ) s
     where m.organization_id = v_b.creator_id and m.removed_at is null and m.bookable and m.role <> 'viewer'
       and (v_b.package_id is null
            or not exists (select 1 from public.package_members pm where pm.package_id = v_b.package_id)
            or exists (select 1 from public.package_members pm where pm.package_id = v_b.package_id and pm.user_id = m.user_id))
     order by (s.state <> 'ok'), lower(coalesce(p.display_name, '')), m.user_id;
end;
$$;

-- Which of a company's people offer a package. An empty list means everyone who is bookable.
create or replace function public.package_set_members(p_package_id uuid, p_user_ids uuid[])
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := public.require_user();
  v_pkg public.packages;
  v_ids uuid[] := coalesce(p_user_ids, '{}');
begin
  select * into v_pkg from public.packages where id = p_package_id;
  if not found or public.org_role_of(v_uid, v_pkg.creator_id) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(v_pkg.creator_id, 'services.manage') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  if exists (
    select 1 from unnest(v_ids) u(id)
     where not exists (select 1 from public.memberships m
                        where m.organization_id = v_pkg.creator_id and m.user_id = u.id
                          and m.removed_at is null and m.bookable and m.role <> 'viewer')
  ) then
    raise exception 'invalid_assignee';
  end if;
  delete from public.package_members where package_id = p_package_id;
  insert into public.package_members (package_id, user_id) select p_package_id, x.u from (select distinct u from unnest(v_ids) u) x;
  perform public.activity_add(v_pkg.creator_id, 'package.offered_by', 'package', v_pkg.id,
    case when cardinality(v_ids) = 0 then v_pkg.name || ' is offered by everyone'
         else v_pkg.name || ' is offered by ' || cardinality(v_ids) || case when cardinality(v_ids) = 1 then ' person' else ' people' end end);
end;
$$;

-- ---------------------------------------------------------------------------
-- What the calendars show
-- ---------------------------------------------------------------------------
-- For a client picking a time: the company's rules and, for each person who could take the package, their hours and
-- when they are busy. The app works out each person's free times with the same engine as for one creator and shows
-- the union. Times only; never what the busy time is.
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
  select * into v_org from public.organizations where id = v_pkg.creator_id and state = 'active';
  select * into v_settings from public.availability_settings where creator_id = v_pkg.creator_id;
  if v_pkg.id is null or v_org.id is null or v_settings.creator_id is null then
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
                     select bb.starts_at, bb.ends_at from public.busy_blocks bb
                      where bb.creator_id = c.user_id
                        and tstzrange(bb.starts_at, bb.ends_at, '[)') && tstzrange(p_from, v_to, '[)')
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

-- For the team: everyone's hours, calendar and bookings. Clients' names appear only on bookings the caller may open.
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
-- Cancelling, refunds and the delivery
-- ---------------------------------------------------------------------------
create or replace function public.refund_quote(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_b   public.bookings;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_b from public.bookings where id = p_booking_id;
  if not found
     or (v_b.client_id is distinct from v_uid and not public.provider_access(v_uid, v_b.creator_id, v_b.assigned_to, 'manage'))
     or v_b.status not in ('held', 'confirmed')
     or v_b.start_at <= now() then
    raise exception 'not_cancellable';
  end if;
  return public.booking_refund_figures(p_booking_id, v_b.client_id is distinct from v_uid);
end;
$$;

create or replace function public.cancel_booking(p_booking_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid        uuid := auth.uid();
  v_row        public.bookings;
  v_by_creator boolean;
  v_figures    jsonb;
  v_left       integer;
  v_pay        public.payments;
  v_available  integer;
  v_part       integer;
  v_refund_ids uuid[] := '{}';
  v_refund_id  uuid;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;

  select * into v_row from public.bookings where id = p_booking_id for update;
  if not found
     or (v_row.client_id is distinct from v_uid and not public.provider_access(v_uid, v_row.creator_id, v_row.assigned_to, 'manage'))
     or v_row.status not in ('held', 'confirmed')
     or v_row.start_at <= now() then
    raise exception 'not_cancellable';
  end if;

  -- The provider side cancelling always returns everything.
  v_by_creator := v_row.client_id is distinct from v_uid;
  v_figures := public.booking_refund_figures(p_booking_id, v_by_creator);
  v_left := (v_figures ->> 'refund_cents')::integer;

  update public.bookings
     set status = 'cancelled', cancelled_at = now(), cancelled_by = v_uid, hold_expires_at = null
   where id = p_booking_id
  returning * into v_row;

  update public.contracts set status = 'voided' where booking_id = p_booking_id and status in ('pending', 'executed');
  update public.payments set status = 'canceled' where booking_id = p_booking_id and status = 'pending' and kind <> 'refund';

  -- Return money from the most recent payment first.
  for v_pay in
    select * from public.payments
     where booking_id = p_booking_id and kind in ('deposit', 'balance') and status = 'succeeded'
     order by paid_at desc, created_at desc
  loop
    exit when v_left <= 0;
    v_available := v_pay.amount_cents - coalesce((
      select sum(r.amount_cents) from public.payments r
       where r.refund_of = v_pay.id and r.status in ('pending', 'succeeded')), 0);
    v_part := least(v_available, v_left);
    if v_part > 0 then
      insert into public.payments (booking_id, kind, refund_of, amount_cents, currency_code, status, method)
      values (p_booking_id, 'refund', v_pay.id, v_part, v_pay.currency_code, 'pending', v_pay.method)
      returning id into v_refund_id;
      v_refund_ids := v_refund_ids || v_refund_id;
      v_left := v_left - v_part;
    end if;
  end loop;

  return jsonb_build_object(
    'booking', to_jsonb(v_row),
    'refund_cents', (v_figures ->> 'refund_cents')::integer,
    'percent', (v_figures ->> 'percent')::integer,
    'refund_ids', to_jsonb(v_refund_ids)
  );
end;
$$;

create or replace function public.share_delivery(p_booking_id uuid, p_url text, p_note text default null)
returns public.bookings
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_row  public.bookings;
  v_url  text;
  v_note text;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_row from public.bookings where id = p_booking_id for update;
  if not found or not public.provider_access(v_uid, v_row.creator_id, v_row.assigned_to, 'manage') then
    raise exception 'not_found';
  end if;
  -- Only a confirmed booking whose shoot has started, and only until the client says they have everything.
  if v_row.status <> 'confirmed' or v_row.receipt_confirmed_at is not null or v_row.start_at > now() then
    raise exception 'not_deliverable';
  end if;

  v_url := public.delivery_url_clean(p_url);
  if v_url is null then
    raise exception 'invalid_delivery_url';
  end if;
  v_note := nullif(public.message_clean(p_note), '');
  if char_length(coalesce(v_note, '')) > public.delivery_note_max_length() then
    raise exception 'note_too_long';
  end if;

  update public.bookings
     set delivery_url = v_url,
         delivery_note = v_note,
         delivered_at = coalesce(delivered_at, now())
   where id = p_booking_id
  returning * into v_row;
  return v_row;
end;
$$;

create or replace function public.get_booking_review(p_booking_id uuid)
returns setof public.reviews
language sql
stable
security definer
set search_path = public
as $$
  select r.*
    from public.reviews r
    join public.bookings b on b.id = r.booking_id
   where r.booking_id = p_booking_id
     and ((select auth.uid()) = b.client_id or public.provider_view(b.creator_id, b.assigned_to))
$$;

-- ---------------------------------------------------------------------------
-- Conversations and notifications reach the right people
-- ---------------------------------------------------------------------------
create or replace function public.bookings_notify_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_to uuid;
begin
  insert into public.messages (booking_id, kind, event, data)
  values (new.id, 'system', 'booked',
          jsonb_build_object('packageName', new.package_name, 'startAt', new.start_at, 'timeZone', new.time_zone));
  for v_to in select * from public.provider_recipients(new.creator_id, new.assigned_to) loop
    perform public.push_enqueue(v_to, 'new_booking', new.id, jsonb_build_object(
      'bookingId', new.id, 'role', 'creator', 'clientName', new.client_name, 'packageName', new.package_name,
      'startAt', new.start_at, 'timeZone', new.time_zone, 'pendingDeposit', new.status = 'held',
      'depositCents', new.deposit_cents, 'currency', new.currency_code,
      'unassigned', new.assigned_to is null), 'new_booking:' || new.id || ':' || v_to);
  end loop;
  return null;
end;
$$;

create or replace function public.bookings_notify_cancelled()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_refund     integer;
  v_by_creator boolean := new.cancelled_by is not null and new.cancelled_by is distinct from new.client_id;
  v_to         uuid;
begin
  select coalesce(sum(p.amount_cents), 0) into v_refund
    from public.payments p
   where p.booking_id = new.id and p.kind = 'refund' and p.status in ('pending', 'succeeded');

  insert into public.messages (booking_id, kind, event, data)
  values (new.id, 'system', 'cancelled', jsonb_build_object(
    'byCreator', v_by_creator, 'refundCents', v_refund, 'currency', new.currency_code));

  -- Tell the other side.
  if v_by_creator then
    perform public.push_enqueue(new.client_id, 'booking_cancelled', new.id, jsonb_build_object(
      'bookingId', new.id, 'role', 'client', 'byName', new.creator_name,
      'packageName', new.package_name, 'startAt', new.start_at, 'timeZone', new.time_zone,
      'refundCents', v_refund, 'currency', new.currency_code), 'booking_cancelled:' || new.id);
  else
    for v_to in select * from public.provider_recipients(new.creator_id, new.assigned_to) loop
      perform public.push_enqueue(v_to, 'booking_cancelled', new.id, jsonb_build_object(
        'bookingId', new.id, 'role', 'creator', 'byName', new.client_name,
        'packageName', new.package_name, 'startAt', new.start_at, 'timeZone', new.time_zone,
        'refundCents', v_refund, 'currency', new.currency_code), 'booking_cancelled:' || new.id || ':' || v_to);
    end loop;
  end if;
  return null;
end;
$$;

create or replace function public.payments_notify_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b  public.bookings;
  v_to uuid;
begin
  select * into v_b from public.bookings where id = new.booking_id;
  -- A payment that couldn't be applied (the booking was cancelled, or its time was taken) has been refunded.
  if not found or v_b.status not in ('confirmed', 'completed') then
    return null;
  end if;

  insert into public.messages (booking_id, kind, event, data)
  values (new.booking_id, 'system', case new.kind when 'deposit' then 'deposit_paid' else 'balance_paid' end,
          jsonb_build_object('amountCents', new.amount_cents, 'currency', new.currency_code));

  for v_to in select * from public.provider_recipients(v_b.creator_id, v_b.assigned_to) loop
    perform public.push_enqueue(v_to, 'payment_received', v_b.id, jsonb_build_object(
      'bookingId', v_b.id, 'role', 'creator', 'paymentKind', new.kind, 'amountCents', new.amount_cents,
      'currency', new.currency_code, 'clientName', v_b.client_name, 'packageName', v_b.package_name),
      'payment_received:' || new.id || ':' || v_to);
  end loop;
  perform public.push_enqueue(v_b.client_id, 'payment_received', v_b.id, jsonb_build_object(
    'bookingId', v_b.id, 'role', 'client', 'paymentKind', new.kind, 'amountCents', new.amount_cents,
    'currency', new.currency_code, 'creatorName', v_b.creator_name, 'packageName', v_b.package_name),
    'payment_received:' || new.id || ':client');
  return null;
end;
$$;

create or replace function public.contracts_notify_executed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b  public.bookings;
  v_to uuid;
begin
  select * into v_b from public.bookings where id = new.booking_id;
  if not found or v_b.status not in ('confirmed', 'completed') then
    return null;
  end if;

  insert into public.messages (booking_id, kind, event)
  values (new.booking_id, 'system', 'contract_signed');

  for v_to in select * from public.provider_recipients(v_b.creator_id, v_b.assigned_to) loop
    perform public.push_enqueue(v_to, 'contract_signed', v_b.id, jsonb_build_object(
      'bookingId', v_b.id, 'role', 'creator', 'packageName', v_b.package_name, 'otherName', v_b.client_name,
      'startAt', v_b.start_at, 'timeZone', v_b.time_zone), 'contract_signed:' || new.id || ':' || v_to);
  end loop;
  perform public.push_enqueue(v_b.client_id, 'contract_signed', v_b.id, jsonb_build_object(
    'bookingId', v_b.id, 'role', 'client', 'packageName', v_b.package_name, 'otherName', v_b.creator_name,
    'startAt', v_b.start_at, 'timeZone', v_b.time_zone), 'contract_signed:' || new.id || ':client');
  return null;
end;
$$;

create or replace function public.messages_notify_text()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b          public.bookings;
  v_by_creator boolean;
  v_to         uuid;
begin
  select * into v_b from public.bookings where id = new.booking_id;
  v_by_creator := new.sender_id is distinct from v_b.client_id;
  if v_by_creator then
    perform public.push_enqueue(v_b.client_id, 'message', v_b.id, jsonb_build_object(
      'bookingId', v_b.id, 'role', 'client', 'senderName', v_b.creator_name, 'preview', left(new.body, 300)),
      'message:' || new.id);
  else
    for v_to in select * from public.provider_recipients(v_b.creator_id, v_b.assigned_to) loop
      perform public.push_enqueue(v_to, 'message', v_b.id, jsonb_build_object(
        'bookingId', v_b.id, 'role', 'creator', 'senderName', v_b.client_name, 'preview', left(new.body, 300)),
        'message:' || new.id || ':' || v_to);
    end loop;
  end if;
  return null;
end;
$$;

create or replace function public.bookings_notify_receipt()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance integer := greatest(new.total_cents - new.deposit_cents, 0);
  v_to      uuid;
begin
  insert into public.messages (booking_id, kind, event, data)
  values (new.id, 'system', 'receipt_confirmed', jsonb_build_object('balanceCents', v_balance, 'currency', new.currency_code));
  for v_to in select * from public.provider_recipients(new.creator_id, new.assigned_to) loop
    perform public.push_enqueue(v_to, 'receipt_confirmed', new.id, jsonb_build_object(
      'bookingId', new.id, 'role', 'creator', 'clientName', new.client_name, 'packageName', new.package_name,
      'balanceCents', v_balance, 'currency', new.currency_code), 'receipt_confirmed:' || new.id || ':' || v_to);
  end loop;
  return null;
end;
$$;

create or replace function public.reviews_notify_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b  public.bookings;
  v_to uuid;
begin
  select * into v_b from public.bookings where id = new.booking_id;
  insert into public.messages (booking_id, kind, event, data)
  values (new.booking_id, 'system', 'reviewed', jsonb_build_object('rating', new.rating));
  for v_to in select * from public.provider_recipients(new.creator_id, v_b.assigned_to) loop
    perform public.push_enqueue(v_to, 'review_received', new.booking_id, jsonb_build_object(
      'bookingId', new.booking_id, 'role', 'creator', 'reviewerName', new.reviewer_name,
      'packageName', new.package_name, 'rating', new.rating), 'review_received:' || new.id || ':' || v_to);
  end loop;
  return null;
end;
$$;

create or replace function public.unread_message_count(p_user uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer
    from public.messages m
    join public.bookings b on b.id = m.booking_id
    left join public.conversation_reads r on r.booking_id = b.id and r.user_id = p_user
   where (b.client_id = p_user or public.provider_access(p_user, b.creator_id, b.assigned_to, 'view'))
     and b.status <> 'expired'
     and m.kind = 'text'
     and m.sender_id is distinct from p_user
     and m.created_at > coalesce(r.read_through, '-infinity'::timestamptz)
$$;

create or replace function public.list_conversations()
returns table (
  booking_id      uuid,
  last_message_id uuid,
  last_kind       text,
  last_event      text,
  last_body       text,
  last_data       jsonb,
  last_sender_id  uuid,
  last_at         timestamptz,
  unread_count    integer
)
language sql
stable
security definer
set search_path = public
as $$
  select b.id, m.id, m.kind, m.event, m.body, m.data, m.sender_id, m.created_at,
         (select count(*)::integer from public.messages u
           where u.booking_id = b.id and u.kind = 'text'
             and u.sender_id is distinct from (select auth.uid())
             and u.created_at > coalesce(r.read_through, '-infinity'::timestamptz))
    from public.bookings b
    cross join lateral (
      select x.* from public.messages x where x.booking_id = b.id order by x.created_at desc, x.id desc limit 1
    ) m
    left join public.conversation_reads r on r.booking_id = b.id and r.user_id = (select auth.uid())
   where (b.client_id = (select auth.uid()) or public.provider_view(b.creator_id, b.assigned_to))
     and b.status <> 'expired'
     and not (b.status = 'held' and b.hold_expires_at <= now())
   order by m.created_at desc, m.id desc
$$;

create or replace function public.send_message(p_booking_id uuid, p_body text, p_client_id uuid default null)
returns public.messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_b    public.bookings;
  v_body text;
  v_row  public.messages;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_b from public.bookings where id = p_booking_id;
  if not found
     or (v_b.client_id is distinct from v_uid and not public.provider_access(v_uid, v_b.creator_id, v_b.assigned_to, 'manage')) then
    raise exception 'not_found';
  end if;

  -- Sending the same message again (a dropped connection) returns the one already stored.
  if p_client_id is not null then
    select * into v_row from public.messages
     where booking_id = p_booking_id and sender_id = v_uid and client_id = p_client_id;
    if found then
      return v_row;
    end if;
  end if;

  -- A hold that ran out never became a booking, and a deleted account has nobody to read the reply.
  if v_b.status = 'expired' or (v_b.status = 'held' and v_b.hold_expires_at <= now())
     or v_b.client_id is null then
    raise exception 'conversation_closed';
  end if;

  v_body := public.message_clean(p_body);
  if char_length(v_body) = 0 then
    raise exception 'invalid_message';
  end if;
  if char_length(v_body) > public.app_message_max_length() then
    raise exception 'message_too_long';
  end if;

  if (select count(*) from public.messages
       where sender_id = v_uid and kind = 'text' and created_at > clock_timestamp() - interval '1 minute') >= 20 then
    raise exception 'rate_limited';
  end if;

  insert into public.messages (booking_id, sender_id, kind, body, client_id)
  values (p_booking_id, v_uid, 'text', v_body, p_client_id)
  on conflict (booking_id, sender_id, client_id) where client_id is not null do nothing
  returning * into v_row;
  if not found then
    -- The same message arrived twice at the same moment, and the other copy won.
    select * into v_row from public.messages
     where booking_id = p_booking_id and sender_id = v_uid and client_id = p_client_id;
    return v_row;
  end if;

  -- Writing back means you have read everything before it.
  insert into public.conversation_reads (booking_id, user_id, read_through)
  values (p_booking_id, v_uid, v_row.created_at)
  on conflict (booking_id, user_id) do update
    set read_through = greatest(public.conversation_reads.read_through, excluded.read_through);

  return v_row;
end;
$$;

create or replace function public.mark_conversation_read(p_booking_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_latest timestamptz;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  if not exists (
    select 1 from public.bookings b
     where b.id = p_booking_id
       and (b.client_id = v_uid or public.provider_access(v_uid, b.creator_id, b.assigned_to, 'view'))
  ) then
    raise exception 'not_found';
  end if;
  select max(created_at) into v_latest from public.messages where booking_id = p_booking_id;
  if v_latest is null then
    return;
  end if;
  insert into public.conversation_reads (booking_id, user_id, read_through)
  values (p_booking_id, v_uid, v_latest)
  on conflict (booking_id, user_id) do update
    set read_through = greatest(public.conversation_reads.read_through, excluded.read_through);
end;
$$;

-- Reminders: the client, the person on the job, and (while nobody is assigned) the people who can assign it.
create or replace function public.enqueue_due_reminders()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_lead  integer;
  v_b     public.bookings;
  v_user  uuid;
  v_role  text;
  v_count integer := 0;
begin
  foreach v_lead in array public.app_reminder_leads() loop
    for v_b in
      select b.* from public.bookings b
       where b.status = 'confirmed'
         and b.start_at > now()
         and now() >= b.start_at - make_interval(mins => v_lead)
         and now() < b.start_at - make_interval(mins => v_lead / 2)
         and b.created_at < b.start_at - make_interval(mins => v_lead)
       order by b.start_at, b.id
    loop
      for v_user, v_role in
        select u.id, u.role from (
          select r as id, 'creator'::text as role from public.provider_recipients(v_b.creator_id, v_b.assigned_to) r
          union
          select v_b.client_id, 'client'
        ) u
      loop
        if v_user is not null and public.push_enqueue(
          v_user, 'shoot_reminder', v_b.id,
          jsonb_build_object(
            'bookingId', v_b.id, 'role', v_role, 'packageName', v_b.package_name,
            'otherName', case when v_role = 'creator' then v_b.client_name else v_b.creator_name end,
            'startAt', v_b.start_at, 'timeZone', v_b.time_zone, 'leadMinutes', v_lead,
            'unassigned', v_role = 'creator' and v_b.assigned_to is null),
          'reminder:' || v_b.id || ':' || v_user || ':' || v_lead || ':' || extract(epoch from v_b.start_at)::bigint
        ) then
          v_count := v_count + 1;
        end if;
      end loop;
    end loop;
  end loop;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- Leaving a team: the person's bookings go back to the queue
-- ---------------------------------------------------------------------------
create or replace function public.member_end(p_org uuid, p_user uuid, p_action text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := public.require_user();
  v_moved integer;
begin
  update public.memberships
     set removed_at = now(), removed_by = v_uid
   where organization_id = p_org and user_id = p_user and removed_at is null;

  with moved as (
    update public.bookings
       set assigned_to = null, assigned_at = null, assignee_share_bps = null
     where creator_id = p_org and assigned_to = p_user and status in ('held', 'confirmed') and end_at > now()
    returning id
  )
  select count(*) into v_moved from moved;
  delete from public.package_members
   where user_id = p_user and package_id in (select id from public.packages where creator_id = p_org);

  perform public.activity_add(p_org, p_action, 'member', p_user,
    case p_action when 'member.left' then coalesce(nullif(public.person_name(p_user), ''), 'A member') || ' left the team'
                  else 'Removed ' || coalesce(nullif(public.person_name(p_user), ''), 'a member') || ' from the team' end
    || case when v_moved > 0 then '; ' || v_moved || case when v_moved = 1 then ' booking' else ' bookings' end
                                  || ' returned to the assignment queue' else '' end,
    jsonb_build_object('returned_bookings', v_moved));
  perform public.org_revalidate_signer(p_org);
end;
$$;

-- ---------------------------------------------------------------------------
-- Upgrading a person to a company, and back
-- ---------------------------------------------------------------------------
-- The person keeps their profile, portfolio, availability, bookings and signed contracts. Services and templates move
-- to the new company. See SPEC D8.
create or replace function public.org_upgrade(
  p_handle        text,
  p_display_name  text,
  p_legal_name    text,
  p_legal_address text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid       uuid := public.require_user();
  v_me        public.creator_profiles;
  v_id        uuid := gen_random_uuid();
  v_packages  integer;
  v_templates integer;
begin
  select * into v_me from public.creator_profiles where id = v_uid and kind = 'person';
  if not found then
    raise exception 'profile_required';
  end if;

  -- A client paying into a booking that is mid-hold must never find it half moved.
  perform public.lock_creator_calendar(v_uid);
  perform public.expire_holds(v_uid);
  if exists (select 1 from public.bookings b where b.creator_id = v_uid and b.status = 'held' and b.hold_expires_at > now()) then
    raise exception 'bookings_in_hold';
  end if;

  begin
    insert into public.creator_profiles (id, kind, handle, display_name, bio, specialties, location_name, latitude, longitude, travel_radius_km)
    values (v_id, 'company', lower(btrim(p_handle)), btrim(p_display_name), v_me.bio, v_me.specialties,
            v_me.location_name, v_me.latitude, v_me.longitude, v_me.travel_radius_km);
  exception
    when unique_violation then
      raise exception 'handle_taken';
    when check_violation then
      raise exception 'invalid_input';
  end;
  insert into public.organizations (id, legal_name, legal_address, created_by)
  values (v_id, btrim(p_legal_name), btrim(coalesce(p_legal_address, '')), v_uid);
  insert into public.memberships (organization_id, user_id, role) values (v_id, v_uid, 'owner');

  -- The company starts with the person's own hours, rules and buffers.
  insert into public.availability_settings (creator_id, time_zone, weekly, blackouts, min_notice_hours, max_advance_days, buffer_minutes, slot_interval_minutes)
  select v_id, time_zone, weekly, blackouts, min_notice_hours, max_advance_days, buffer_minutes, slot_interval_minutes
    from public.availability_settings where creator_id = v_uid;

  perform set_config('slate.moving_services', 'on', true);
  update public.contract_templates set creator_id = v_id where creator_id = v_uid;
  get diagnostics v_templates = row_count;
  update public.packages set creator_id = v_id where creator_id = v_uid;
  get diagnostics v_packages = row_count;
  perform set_config('slate.moving_services', 'off', true);

  perform public.activity_add(v_id, 'org.upgraded', 'company', v_id,
    'Upgraded from an individual account: moved ' || v_packages || case when v_packages = 1 then ' service' else ' services' end
    || ' and ' || v_templates || case when v_templates = 1 then ' contract template' else ' contract templates' end,
    jsonb_build_object('services', v_packages, 'templates', v_templates));
  return public.org_overview(v_id);
end;
$$;

-- Back to working alone. Only the Owner, only when they are the only member and nothing is coming up. The services
-- return to the person; the company is closed, but kept, because signed contracts name it.
create or replace function public.org_downgrade(p_org uuid)
returns jsonb
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
  if (select count(*) from public.memberships where organization_id = p_org and removed_at is null) <> 1 then
    raise exception 'team_not_empty';
  end if;
  perform public.lock_creator_calendar(p_org);
  perform public.expire_holds(p_org);
  if exists (
    select 1 from public.bookings b
     where b.creator_id = p_org and b.status in ('held', 'confirmed') and b.end_at > now()
  ) then
    raise exception 'has_upcoming_bookings';
  end if;

  perform set_config('slate.moving_services', 'on', true);
  update public.contract_templates set creator_id = v_uid where creator_id = p_org;
  update public.packages set creator_id = v_uid where creator_id = p_org;
  perform set_config('slate.moving_services', 'off', true);
  delete from public.package_members where package_id in (select id from public.packages where creator_id = v_uid);

  perform public.activity_add(p_org, 'org.downgraded', 'company', p_org, 'Went back to an individual account');
  perform public.org_close(p_org);
  return public.my_accounts();
end;
$$;

-- The Owner of a company can't delete their account until they hand it over or close it. The Edge Function asks.
create or replace function public.account_blockers(p_user uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('organization_id', o.id, 'name', p.display_name) order by p.display_name), '[]'::jsonb)
    from public.memberships m
    join public.organizations o on o.id = m.organization_id and o.state <> 'closed'
    join public.creator_profiles p on p.id = o.id
   where m.user_id = p_user and m.role = 'owner' and m.removed_at is null;
$$;

-- ---------------------------------------------------------------------------
-- org_overview now includes the caller's own hours
-- ---------------------------------------------------------------------------
create or replace function public.org_overview(p_org uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid  uuid := public.require_user();
  v_org  public.organizations;
  v_me   public.memberships;
  v_prof public.creator_profiles;
begin
  select * into v_me from public.memberships where organization_id = p_org and user_id = v_uid and removed_at is null;
  if not found then
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
    'my_role', v_me.role,
    'my_title', v_me.title,
    'my_hours', v_me.weekly,
    'seats', public.org_seat_counts(p_org)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- The activity log: bookings, contracts, prices
-- ---------------------------------------------------------------------------
create or replace function public.bookings_log_company()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.organizations o where o.id = new.creator_id) then
    return null;
  end if;
  if tg_op = 'INSERT' then
    perform public.activity_add(new.creator_id, 'booking.created', 'booking', new.id,
      'New booking: ' || new.package_name || ' for ' || coalesce(nullif(new.client_name, ''), 'a client')
      || case when new.assigned_to is not null then ', with ' || coalesce(nullif(public.person_name(new.assigned_to), ''), 'a member')
              else ', waiting for someone to take it' end,
      jsonb_build_object('requested_member', new.requested_member));
  elsif new.status is distinct from old.status then
    if new.status = 'cancelled' then
      perform public.activity_add(new.creator_id, 'booking.cancelled', 'booking', new.id,
        'Cancelled ' || new.package_name || ' for ' || coalesce(nullif(new.client_name, ''), 'a client'));
    elsif new.status = 'completed' then
      perform public.activity_add(new.creator_id, 'booking.completed', 'booking', new.id,
        'Completed ' || new.package_name || ' for ' || coalesce(nullif(new.client_name, ''), 'a client'));
    end if;
  end if;
  if tg_op = 'UPDATE' and new.delivery_url is distinct from old.delivery_url and new.delivery_url is not null then
    perform public.activity_add(new.creator_id, 'booking.delivered', 'booking', new.id,
      'Shared the final files for ' || new.package_name || ' (' || coalesce(nullif(new.client_name, ''), 'a client') || ')');
  end if;
  return null;
end;
$$;

create trigger bookings_log_company
  after insert or update on public.bookings
  for each row execute function public.bookings_log_company();

create or replace function public.contracts_log_company()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b public.bookings;
begin
  if not exists (select 1 from public.organizations o where o.id = new.creator_id) then
    return null;
  end if;
  select * into v_b from public.bookings where id = new.booking_id;
  if new.status = 'executed' then
    perform public.activity_add(new.creator_id, 'contract.executed', 'contract', new.id,
      'Contract signed for ' || coalesce(v_b.package_name, 'a booking') || ' (' || coalesce(nullif(v_b.client_name, ''), 'a client') || ')'
      || case when new.countersigner_name is not null
              then ', countersigned by ' || new.countersigner_name || coalesce(' (' || nullif(new.countersigner_title, '') || ')', '')
              else '' end);
  elsif new.status = 'voided' and old.status is distinct from 'voided' then
    perform public.activity_add(new.creator_id, 'contract.voided', 'contract', new.id,
      'Contract voided for ' || coalesce(v_b.package_name, 'a booking') || ' (' || coalesce(nullif(v_b.client_name, ''), 'a client') || ')');
  end if;
  return null;
end;
$$;

create trigger contracts_log_company
  after update of status on public.contracts
  for each row
  when (old.status is distinct from new.status)
  execute function public.contracts_log_company();

create or replace function public.packages_log_company()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid := case when tg_op = 'DELETE' then old.creator_id else new.creator_id end;
begin
  if not exists (select 1 from public.organizations o where o.id = v_owner and o.state <> 'closed') then
    return null;
  end if;
  -- A person's services moving in or out is logged once, by the upgrade itself.
  if coalesce(current_setting('slate.moving_services', true), '') = 'on' then
    return null;
  end if;
  if tg_op = 'INSERT' then
    perform public.activity_add(v_owner, 'package.created', 'package', new.id,
      'Added the service ' || new.name || ' at ' || public.contract_money(new.price_cents, new.currency_code));
  elsif tg_op = 'DELETE' then
    perform public.activity_add(v_owner, 'package.deleted', 'package', old.id, 'Deleted the service ' || old.name);
  else
    if new.price_cents is distinct from old.price_cents then
      perform public.activity_add(v_owner, 'package.price_changed', 'package', new.id,
        'Changed the price of ' || new.name || ' from ' || public.contract_money(old.price_cents, old.currency_code)
        || ' to ' || public.contract_money(new.price_cents, new.currency_code),
        jsonb_build_object('from', old.price_cents, 'to', new.price_cents));
    end if;
    if new.deposit_cents is distinct from old.deposit_cents then
      perform public.activity_add(v_owner, 'package.deposit_changed', 'package', new.id,
        'Changed the deposit of ' || new.name || ' from ' || public.contract_money(old.deposit_cents, old.currency_code)
        || ' to ' || public.contract_money(new.deposit_cents, new.currency_code),
        jsonb_build_object('from', old.deposit_cents, 'to', new.deposit_cents));
    end if;
    if new.is_published is distinct from old.is_published then
      perform public.activity_add(v_owner, 'package.visibility_changed', 'package', new.id,
        case when new.is_published then 'Published ' else 'Hid ' end || new.name);
    end if;
    if new.name is distinct from old.name then
      perform public.activity_add(v_owner, 'package.renamed', 'package', new.id,
        'Renamed the service ' || old.name || ' to ' || new.name);
    end if;
    if new.contract_template_id is distinct from old.contract_template_id then
      perform public.activity_add(v_owner, 'package.contract_changed', 'package', new.id,
        'Changed the contract for ' || new.name);
    end if;
  end if;
  return null;
end;
$$;

create trigger packages_log_company
  after insert or update or delete on public.packages
  for each row execute function public.packages_log_company();

create or replace function public.templates_log_company()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid := case when tg_op = 'DELETE' then old.creator_id else new.creator_id end;
begin
  if not exists (select 1 from public.organizations o where o.id = v_owner and o.state <> 'closed') then
    return null;
  end if;
  if coalesce(current_setting('slate.moving_services', true), '') = 'on' then
    return null;
  end if;
  if tg_op = 'INSERT' then
    perform public.activity_add(v_owner, 'template.created', 'template', new.id, 'Added the contract template ' || new.title);
  elsif tg_op = 'DELETE' then
    perform public.activity_add(v_owner, 'template.deleted', 'template', old.id, 'Deleted the contract template ' || old.title);
  elsif new.version is distinct from old.version then
    perform public.activity_add(v_owner, 'template.edited', 'template', new.id,
      'Edited the contract template ' || new.title || ' (version ' || new.version || ')');
  end if;
  return null;
end;
$$;

create trigger templates_log_company
  after insert or update or delete on public.contract_templates
  for each row execute function public.templates_log_company();

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function
  public.provider_access(uuid, uuid, uuid, text),
  public.provider_recipients(uuid, uuid),
  public.bookings_assignee_guard(),
  public.bookings_log_company(),
  public.contracts_log_company(),
  public.packages_log_company(),
  public.templates_log_company(),
  public.member_slot_state(uuid, uuid, jsonb, public.availability_settings, timestamptz, timestamptz, timestamptz, uuid),
  public.package_candidates(uuid, uuid),
  public.connect_authorize(uuid, uuid),
  public.account_blockers(uuid),
  public.is_booking_party(uuid, uuid)
from public, anon, authenticated;

-- Policies and the app call these. They only ever answer about the signed-in user.
grant execute on function
  public.provider_view(uuid, uuid),
  public.provider_manage(uuid, uuid),
  public.can_view_contract(uuid),
  public.weekly_valid(jsonb),
  public.effective_weekly(jsonb, jsonb)
to anon, authenticated;

revoke execute on function
  public.create_booking(uuid, uuid[], timestamptz, text, text, text, jsonb, uuid),
  public.assign_booking(uuid, uuid), public.assignment_queue(uuid), public.assignment_options(uuid),
  public.package_set_members(uuid, uuid[]), public.team_availability(uuid, uuid, timestamptz, timestamptz),
  public.team_calendar(uuid, timestamptz, timestamptz, uuid[]), public.member_set_hours(uuid, jsonb),
  public.org_upgrade(text, text, text, text), public.org_downgrade(uuid)
from public, anon;
grant execute on function
  public.create_booking(uuid, uuid[], timestamptz, text, text, text, jsonb, uuid),
  public.assign_booking(uuid, uuid), public.assignment_queue(uuid), public.assignment_options(uuid),
  public.package_set_members(uuid, uuid[]), public.team_availability(uuid, uuid, timestamptz, timestamptz),
  public.team_calendar(uuid, timestamptz, timestamptz, uuid[]), public.member_set_hours(uuid, jsonb),
  public.org_upgrade(text, text, text, text), public.org_downgrade(uuid)
to authenticated;
