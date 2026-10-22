-- Company accounts, part 3: seat-based billing.
--
-- A company pays for seats with Stripe Billing: one subscription per company, its quantity the number of seats. This
-- migration holds what the app needs to know about it and the rules around it. It never talks to Stripe: Stripe's
-- signed webhook reports what happened (billing_record_subscription), and a job pushes seat changes back
-- (billing_sync_due / billing_sync_done). Like payments, the app cannot say a plan is paid for.
--
-- Seats used = active members. Seats billed = max(the floor, seats used). Pending invites are not billed until they
-- are accepted but count toward the maximum. More seats are charged at once (prorated by Stripe); fewer apply from
-- the next invoice with no credit for the rest of the period.
--
-- A company can be set up before it pays, but takes no members and no bookings until the plan is trialing or active.
-- A failed payment starts a grace period; after it the company becomes read only (lapsed) until the plan recovers.

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
-- billing.required: turn it off in a project that has no Stripe yet (local development, tests). On by default.
alter table public.app_settings drop constraint grace_days_make_sense;
alter table public.app_settings
  add constraint grace_days_make_sense check (
    key <> 'billing' or (
      (value ->> 'grace_days')::integer between 0 and 60
      and (value ->> 'required' is null or value ->> 'required' in ('true', 'false'))
    )
  );
update public.app_settings set value = value || '{"required": true}'::jsonb where key = 'billing';

create or replace function public.app_billing_required()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((select (value ->> 'required')::boolean from public.app_settings where key = 'billing'), true);
$$;

-- ---------------------------------------------------------------------------
-- The subscription
-- ---------------------------------------------------------------------------
create table public.org_subscriptions (
  organization_id        uuid primary key references public.organizations (id) on delete restrict,
  stripe_customer_id     text unique,
  stripe_subscription_id text unique,
  status                 text not null default 'none' check (status in ('none', 'trialing', 'active', 'past_due', 'canceled')),
  -- The quantity on the Stripe subscription, as Stripe last told us.
  seats_billed           integer not null default 0 check (seats_billed >= 0),
  -- What it should be, kept up to date as people join and leave.
  seats_wanted           integer not null default 0 check (seats_wanted >= 0),
  current_period_end     timestamptz,
  trial_end              timestamptz,
  cancel_at_period_end   boolean not null default false,
  grace_until            timestamptz,
  updated_at             timestamptz not null default now()
);

create trigger org_subscriptions_set_updated_at
  before update on public.org_subscriptions
  for each row execute function public.set_updated_at();

alter table public.org_subscriptions enable row level security;

create policy "Owners read their plan"
  on public.org_subscriptions for select
  to authenticated
  using (public.acts_for(organization_id, 'billing.manage'));

-- ---------------------------------------------------------------------------
-- Seats: one rule, used everywhere
-- ---------------------------------------------------------------------------
-- What adding (delta > 0) or removing (delta < 0) people does. SlateTests/Fixtures/seat_rules.json holds cases for
-- this and for SeatPlan in Swift, and both suites check them.
create or replace function public.seat_plan(p_used integer, p_delta integer, p_min integer, p_max integer)
returns jsonb
language sql
immutable
as $$
  select jsonb_build_object(
    'used', greatest(p_used, 0),
    'used_after', greatest(p_used + p_delta, 0),
    'billed_now', greatest(p_min, p_used),
    'billed_after', greatest(p_min, p_used + p_delta),
    'allowed', p_used + p_delta <= p_max,
    'change', case
      when greatest(p_min, p_used + p_delta) > greatest(p_min, p_used) then 'increase'
      when greatest(p_min, p_used + p_delta) < greatest(p_min, p_used) then 'decrease'
      else 'none' end
  );
$$;

create or replace function public.org_seats_wanted(p_org uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select greatest(public.app_seat_minimum(), count(*)::integer)
    from public.memberships where organization_id = p_org and removed_at is null;
$$;

create or replace function public.memberships_seats_changed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.org_subscriptions s set seats_wanted = public.org_seats_wanted(new.organization_id)
   where s.organization_id = new.organization_id;
  return null;
end;
$$;

create trigger memberships_seats_changed
  after insert or update of removed_at on public.memberships
  for each row execute function public.memberships_seats_changed();

-- ---------------------------------------------------------------------------
-- Is the plan good?
-- ---------------------------------------------------------------------------
create or replace function public.org_billing_ok(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select o.state = 'active' and (
      not public.app_billing_required()
      or coalesce((
        select s.status in ('trialing', 'active') or (s.status = 'past_due' and coalesce(s.grace_until, now()) > now())
          from public.org_subscriptions s where s.organization_id = o.id), false)
    )
    from public.organizations o where o.id = p_org
  ), false);
$$;

-- Part 1 only asked that the company was active. Now it must be paid up too.
create or replace function public.org_can_grow(p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$ select public.org_billing_ok(p_org) $$;

-- Invites follow the same rule when they are opened and accepted.
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
     or not public.org_can_grow(v_invite.organization_id) then
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
     or not public.org_can_grow(v_invite.organization_id) then
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

-- A client can only book a company whose plan is good.
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
  if found and not public.org_billing_ok(v_org.id) then
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

-- ---------------------------------------------------------------------------
-- What Stripe tells us
-- ---------------------------------------------------------------------------
-- Moves a company between active, lapsed and (never out of) closed to match its plan.
create or replace function public.org_apply_billing(p_org uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state text;
  v_sub   public.org_subscriptions;
begin
  select state into v_state from public.organizations where id = p_org for update;
  select * into v_sub from public.org_subscriptions where organization_id = p_org;
  if not found or v_state is null or v_state = 'closed' then
    return;
  end if;

  if v_sub.status in ('trialing', 'active') and v_state = 'lapsed' then
    update public.organizations set state = 'active' where id = p_org;
    perform public.activity_add(p_org, 'plan.recovered', 'company', p_org, 'The plan is active again');
  elsif v_state = 'active' and (
          v_sub.status = 'canceled'
          or (v_sub.status = 'past_due' and v_sub.grace_until is not null and v_sub.grace_until <= now())) then
    update public.organizations set state = 'lapsed' where id = p_org;
    perform public.activity_add(p_org, 'plan.lapsed', 'company', p_org,
      case v_sub.status when 'canceled' then 'The plan ended: the company is now read only'
                        else 'Payment is overdue: the company is now read only' end);
  end if;
end;
$$;

-- The webhook's record of a subscription. Stripe's statuses are folded into five before they get here.
create or replace function public.billing_record_subscription(
  p_org                  uuid,
  p_customer_id          text,
  p_subscription_id      text,
  p_status               text,
  p_quantity             integer,
  p_period_end           timestamptz,
  p_trial_end            timestamptz,
  p_cancel_at_period_end boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_old   public.org_subscriptions;
  v_new   public.org_subscriptions;
  v_grace timestamptz;
begin
  if p_status not in ('trialing', 'active', 'past_due', 'canceled') then
    raise exception 'invalid_status';
  end if;
  if not exists (select 1 from public.organizations where id = p_org) then
    raise exception 'not_found';
  end if;

  select * into v_old from public.org_subscriptions where organization_id = p_org for update;
  v_grace := case
    when p_status = 'past_due' then coalesce(v_old.grace_until, now() + make_interval(days => public.app_grace_days()))
    else null end;

  insert into public.org_subscriptions (organization_id, stripe_customer_id, stripe_subscription_id, status, seats_billed,
                                        seats_wanted, current_period_end, trial_end, cancel_at_period_end, grace_until)
  values (p_org, p_customer_id, p_subscription_id, p_status, greatest(coalesce(p_quantity, 0), 0),
          public.org_seats_wanted(p_org), p_period_end, p_trial_end, coalesce(p_cancel_at_period_end, false), v_grace)
  on conflict (organization_id) do update
    set stripe_customer_id = coalesce(excluded.stripe_customer_id, public.org_subscriptions.stripe_customer_id),
        stripe_subscription_id = excluded.stripe_subscription_id,
        status = excluded.status,
        seats_billed = excluded.seats_billed,
        seats_wanted = excluded.seats_wanted,
        current_period_end = excluded.current_period_end,
        trial_end = excluded.trial_end,
        cancel_at_period_end = excluded.cancel_at_period_end,
        grace_until = excluded.grace_until
  returning * into v_new;

  if v_old.status is distinct from v_new.status then
    perform public.activity_add(p_org, 'plan.' || v_new.status, 'company', p_org,
      case v_new.status
        when 'trialing' then 'Started the plan with a trial, ' || v_new.seats_billed || ' seats'
        when 'active' then 'The plan is active: ' || v_new.seats_billed || ' seats'
        when 'past_due' then 'A payment for the plan failed'
        else 'The plan was cancelled' end,
      jsonb_build_object('seats', v_new.seats_billed));
  elsif v_old.seats_billed is distinct from v_new.seats_billed and v_old.organization_id is not null then
    perform public.activity_add(p_org, 'plan.seats_changed', 'company', p_org,
      'Seats billed changed from ' || v_old.seats_billed || ' to ' || v_new.seats_billed,
      jsonb_build_object('from', v_old.seats_billed, 'to', v_new.seats_billed));
  end if;

  perform public.org_apply_billing(p_org);
  return jsonb_build_object('organization_id', p_org, 'status', v_new.status, 'state', (select state from public.organizations where id = p_org));
end;
$$;

-- Which company owns a Stripe customer, for events that arrive without our metadata.
create or replace function public.billing_org_for_customer(p_customer_id text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select organization_id from public.org_subscriptions where stripe_customer_id = p_customer_id;
$$;

-- Companies whose payment is overdue past the grace period become read only. Run it on a schedule.
create or replace function public.billing_sweep()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_org   uuid;
  v_count integer := 0;
begin
  for v_org in
    select s.organization_id from public.org_subscriptions s
      join public.organizations o on o.id = s.organization_id
     where o.state = 'active' and s.status = 'past_due' and s.grace_until <= now()
     order by s.organization_id
  loop
    perform public.org_apply_billing(v_org);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------------
-- What the billing functions (Edge Functions) ask
-- ---------------------------------------------------------------------------
create or replace function public.billing_authorize(p_user uuid, p_org uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select p_user is not null and public.org_perm_for(p_user, p_org, 'billing.manage');
$$;

-- Everything needed to open Stripe Checkout or the billing portal for a company.
create or replace function public.billing_prepare(p_user uuid, p_org uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sub public.org_subscriptions;
  v_org public.organizations;
begin
  if not public.billing_authorize(p_user, p_org) then
    raise exception 'not_found';
  end if;
  select * into v_org from public.organizations where id = p_org;
  insert into public.org_subscriptions (organization_id, seats_wanted)
  values (p_org, public.org_seats_wanted(p_org))
  on conflict (organization_id) do nothing;
  select * into v_sub from public.org_subscriptions where organization_id = p_org;
  return jsonb_build_object(
    'organization_id', p_org,
    'name', (select display_name from public.creator_profiles where id = p_org),
    'customer_id', v_sub.stripe_customer_id,
    'subscription_id', v_sub.stripe_subscription_id,
    'status', v_sub.status,
    'seats_wanted', public.org_seats_wanted(p_org),
    -- A company that has never had a plan gets the trial; one that cancelled does not get it twice.
    'trial_eligible', v_sub.stripe_subscription_id is null,
    'state', v_org.state
  );
end;
$$;

create or replace function public.billing_save_customer(p_org uuid, p_customer_id text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.org_subscriptions set stripe_customer_id = p_customer_id
   where organization_id = p_org and stripe_customer_id is null;
$$;

-- Plans whose Stripe quantity needs to change, and closed companies whose subscription needs to end.
create or replace function public.billing_sync_due()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'organization_id', s.organization_id,
           'subscription_id', s.stripe_subscription_id,
           'seats_wanted', public.org_seats_wanted(s.organization_id),
           'seats_billed', s.seats_billed,
           'closed', o.state = 'closed'
         ) order by s.organization_id), '[]'::jsonb)
    from public.org_subscriptions s
    join public.organizations o on o.id = s.organization_id
   where s.stripe_subscription_id is not null
     and s.status in ('trialing', 'active', 'past_due')
     and (o.state = 'closed' or s.seats_billed <> public.org_seats_wanted(s.organization_id));
$$;

create or replace function public.billing_sync_done(p_org uuid, p_seats integer, p_cancelled boolean default false)
returns void
language sql
security definer
set search_path = public
as $$
  update public.org_subscriptions
     set seats_billed = case when p_cancelled then seats_billed else greatest(coalesce(p_seats, seats_billed), 0) end,
         status = case when p_cancelled then 'canceled' else status end
   where organization_id = p_org;
$$;

-- ---------------------------------------------------------------------------
-- What the Owner sees
-- ---------------------------------------------------------------------------
create or replace function public.billing_overview(p_org uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sub  public.org_subscriptions;
  v_seat jsonb;
begin
  perform public.require_user();
  if public.org_role_of(auth.uid(), p_org) is null then
    raise exception 'not_found';
  end if;
  if not public.acts_for(p_org, 'billing.manage') then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  select * into v_sub from public.org_subscriptions where organization_id = p_org;
  v_seat := public.org_seat_counts(p_org);
  return jsonb_build_object(
    'required', public.app_billing_required(),
    'status', coalesce(v_sub.status, 'none'),
    'seats', v_seat,
    'seats_billed_by_stripe', coalesce(v_sub.seats_billed, 0),
    'current_period_end', v_sub.current_period_end,
    'trial_end', v_sub.trial_end,
    'cancel_at_period_end', coalesce(v_sub.cancel_at_period_end, false),
    'grace_until', v_sub.grace_until,
    'state', (select state from public.organizations where id = p_org)
  );
end;
$$;

-- "What will happen if I add or remove this many people?" For the people who can do it.
create or replace function public.billing_preview(p_org uuid, p_delta integer)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_used integer;
  v_sub  public.org_subscriptions;
  v_plan jsonb;
begin
  perform public.require_user();
  if public.org_role_of(auth.uid(), p_org) is null then
    raise exception 'not_found';
  end if;
  if not (public.acts_for(p_org, 'team.manage') or public.acts_for(p_org, 'billing.manage')) then
    raise exception 'not_allowed' using errcode = '42501';
  end if;
  select count(*)::integer into v_used from public.memberships where organization_id = p_org and removed_at is null;
  select * into v_sub from public.org_subscriptions where organization_id = p_org;
  v_plan := public.seat_plan(v_used, coalesce(p_delta, 0), public.app_seat_minimum(), public.app_seat_maximum());
  return v_plan || jsonb_build_object(
    'effective', case v_plan ->> 'change' when 'increase' then 'now' when 'decrease' then 'next_invoice' else 'none' end,
    'period_end', v_sub.current_period_end
  );
end;
$$;

-- Everyone in the company can see whether the plan needs attention, without seeing invoices.
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
  v_sub  public.org_subscriptions;
begin
  select * into v_me from public.memberships where organization_id = p_org and user_id = v_uid and removed_at is null;
  if not found then
    raise exception 'not_found';
  end if;
  select * into v_org from public.organizations where id = p_org;
  select * into v_prof from public.creator_profiles where id = p_org;
  select * into v_sub from public.org_subscriptions where organization_id = p_org;
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
    'seats', public.org_seat_counts(p_org),
    'plan', jsonb_build_object(
      'required', public.app_billing_required(),
      'status', coalesce(v_sub.status, 'none'),
      'ok', public.org_billing_ok(p_org),
      'grace_until', v_sub.grace_until,
      'cancel_at_period_end', coalesce(v_sub.cancel_at_period_end, false),
      'period_end', v_sub.current_period_end)
  );
end;
$$;

-- A client booking page needs to know the company is open for business.
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

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
-- Everything that records or changes a plan is for the Edge Functions (the service role) only.
revoke execute on function
  public.app_billing_required(),
  public.org_seats_wanted(uuid),
  public.memberships_seats_changed(),
  public.org_billing_ok(uuid),
  public.org_apply_billing(uuid),
  public.billing_record_subscription(uuid, text, text, text, integer, timestamptz, timestamptz, boolean),
  public.billing_org_for_customer(text),
  public.billing_sweep(),
  public.billing_authorize(uuid, uuid),
  public.billing_prepare(uuid, uuid),
  public.billing_save_customer(uuid, text),
  public.billing_sync_due(),
  public.billing_sync_done(uuid, integer, boolean)
from public, anon, authenticated;

grant execute on function public.seat_plan(integer, integer, integer, integer) to anon, authenticated;

revoke execute on function public.billing_overview(uuid), public.billing_preview(uuid, integer) from public, anon;
grant execute on function public.billing_overview(uuid), public.billing_preview(uuid, integer) to authenticated;
