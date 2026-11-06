-- Company accounts, part 4: the company plan is bought with Apple's In-App Purchase.
--
-- The plan is an auto-renewable subscription that covers a number of people (5, 10, 15, 20, 25), because Apple's
-- subscriptions can't be bought by quantity: each step is its own product (SPEC D6, D7). The Owner buys it in the app with
-- Apple's purchase sheet, which pays with Apple Pay, a card in Wallet or Apple Account balance.
--
-- Like payments and the Stripe plan before it, the app can never say a plan is paid for. Two Edge Functions record it, and
-- only from data Apple has signed (checked with Apple's own certificate chain): `apple-verify` after a purchase and
-- `apple-notifications` for everything that happens later (renewals, a failed payment, a refund, an end). This file holds
-- what they write and the rules around it. It reuses the plan states of the Stripe plan (none, trialing, active, past due,
-- canceled) and the same grace period, so the rest of the system (invites, bookings, read only) needs no new rule.
--
-- A purchase is tied to a company by the id the app sets on it (Apple's appAccountToken is the company's id), and one
-- Apple subscription can belong to one company only.

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------
-- The smallest plan covers 5 people.
update public.app_settings set value = jsonb_set(value, '{minimum}', '5') where key = 'seats';

-- ---------------------------------------------------------------------------
-- The plans on offer: one row per product in App Store Connect
-- ---------------------------------------------------------------------------
-- Closed to the API. The price and the free trial are set in App Store Connect and shown from what Apple returns, so
-- nothing here knows them. `active = false` stops offering a step but keeps honouring people who already bought it.
create table public.apple_plans (
  product_id text primary key check (product_id ~ '^[A-Za-z0-9._-]{3,100}$'),
  seats      integer not null check (seats between 1 and 1000),
  sort       integer not null,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
alter table public.apple_plans enable row level security;
revoke all on public.apple_plans from anon, authenticated;

insert into public.apple_plans (product_id, seats, sort) values
  ('com.slateproapp.app.company.team5',  5,  1),
  ('com.slateproapp.app.company.team10', 10, 2),
  ('com.slateproapp.app.company.team15', 15, 3),
  ('com.slateproapp.app.company.team20', 20, 4),
  ('com.slateproapp.app.company.team25', 25, 5);

create or replace function public.apple_plan_list()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object('product_id', product_id, 'seats', seats) order by sort, seats), '[]'::jsonb)
    from public.apple_plans where active;
$$;

-- What the app shows and checks against: the same call as before, now with the plans.
create or replace function public.team_config()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'seat_minimum', public.app_seat_minimum(),
    'seat_maximum', public.app_seat_maximum(),
    'invite_expiry_days', public.app_invite_days(),
    'grace_days', public.app_grace_days(),
    'apple_plans', public.apple_plan_list()
  );
$$;

-- ---------------------------------------------------------------------------
-- The subscription row learns about Apple
-- ---------------------------------------------------------------------------
alter table public.org_subscriptions
  add column provider text not null default 'stripe' check (provider in ('stripe', 'apple')),
  -- Apple's id for a subscription, the same through every renewal and every change of step.
  add column apple_original_transaction_id text unique,
  add column apple_product_id text,
  add column apple_environment text check (apple_environment in ('Sandbox', 'Production')),
  -- When Apple signed the latest thing we recorded, so a late, older message can't undo a newer one.
  add column apple_signed_at timestamptz,
  -- How many people the plan covers (null for a Stripe plan).
  add column seats_covered integer check (seats_covered > 0);

-- ---------------------------------------------------------------------------
-- How many people a company may have
-- ---------------------------------------------------------------------------
-- What a live Apple plan covers, else the general maximum. (A company that is over its limit keeps its members; it just
-- takes no new invites until it is under: the check is "used + pending >= maximum" where invites are made.)
create or replace function public.org_seat_cap(p_org uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select least(s.seats_covered, public.app_seat_maximum())
      from public.org_subscriptions s
     where s.organization_id = p_org and s.provider = 'apple' and s.seats_covered is not null
       and s.status in ('trialing', 'active', 'past_due')
  ), public.app_seat_maximum());
$$;

-- `maximum` is now the company's own limit, so the invite check and every screen use it without changing.
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
    'maximum', public.org_seat_cap(p_org)
  )
  from (select count(*)::integer as n from public.memberships where organization_id = p_org and removed_at is null) u;
$$;

-- Storage follows the people a live plan covers (per person, shared by the company); without one, the team's size.
create or replace function public.org_storage_seats(p_org uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select s.seats_covered
      from public.org_subscriptions s
     where s.organization_id = p_org and s.provider = 'apple' and s.seats_covered is not null
       and s.status in ('trialing', 'active', 'past_due')
  ), public.org_seats_wanted(p_org));
$$;

create or replace function public.files_owner_allowance_bytes(p_owner uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select public.files_allowance_bytes(p.kind = 'person', case when p.kind = 'company' then public.org_storage_seats(p.id) else 0 end)
    from public.creator_profiles p where p.id = p_owner;
$$;

-- ---------------------------------------------------------------------------
-- What Apple tells us
-- ---------------------------------------------------------------------------
-- Records a subscription from data the Edge Function has already checked against Apple's signature. Apple's own
-- statuses are folded into the five before they get here. Safe to call again with the same facts, and a message older
-- than the one already recorded is ignored.
create or replace function public.apple_record_subscription(
  p_org                     uuid,
  p_original_transaction_id text,
  p_product_id              text,
  p_environment             text,
  p_status                  text,
  p_period_end              timestamptz,
  p_trial_end               timestamptz,
  p_renews                  boolean,
  p_grace_until             timestamptz,
  p_signed_at               timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_state text;
  v_seats integer;
  v_old   public.org_subscriptions;
  v_new   public.org_subscriptions;
  v_grace timestamptz;
begin
  if p_status not in ('trialing', 'active', 'past_due', 'canceled')
     or p_environment not in ('Sandbox', 'Production')
     or coalesce(p_original_transaction_id, '') = ''
     or p_signed_at is null then
    raise exception 'invalid_input';
  end if;

  select state into v_state from public.organizations where id = p_org for update;
  if v_state is null then
    raise exception 'not_found';
  end if;
  if v_state = 'closed' then
    return jsonb_build_object('organization_id', p_org, 'ignored', 'closed');
  end if;

  select seats into v_seats from public.apple_plans where product_id = p_product_id;
  if v_seats is null then
    raise exception 'unknown_product';
  end if;

  -- One Apple subscription belongs to one company.
  if exists (select 1 from public.org_subscriptions
              where apple_original_transaction_id = p_original_transaction_id and organization_id <> p_org) then
    raise exception 'transaction_in_use';
  end if;

  select * into v_old from public.org_subscriptions where organization_id = p_org for update;
  if found then
    if v_old.provider = 'apple' and v_old.apple_original_transaction_id = p_original_transaction_id then
      if v_old.apple_signed_at is not null and p_signed_at < v_old.apple_signed_at then
        return jsonb_build_object('organization_id', p_org, 'status', v_old.status, 'ignored', 'stale');
      end if;
    elsif v_old.status in ('trialing', 'active', 'past_due') then
      -- Another plan (a different Apple subscription, or a Stripe one) is still running.
      raise exception 'plan_exists';
    end if;
  end if;

  -- A failed payment gets a grace period: Apple's own if it gave one, else the usual few days. A second failure doesn't
  -- restart the clock (but a later date from Apple extends it).
  v_grace := case
    when p_status <> 'past_due' then null
    when v_old.status = 'past_due' and v_old.grace_until is not null then greatest(v_old.grace_until, coalesce(p_grace_until, v_old.grace_until))
    else coalesce(p_grace_until, now() + make_interval(days => public.app_grace_days()))
  end;

  insert into public.org_subscriptions (organization_id, provider, apple_original_transaction_id, apple_product_id,
                                        apple_environment, apple_signed_at, seats_covered, status, seats_billed, seats_wanted,
                                        current_period_end, trial_end, cancel_at_period_end, grace_until)
  values (p_org, 'apple', p_original_transaction_id, p_product_id, p_environment, p_signed_at, v_seats, p_status, v_seats,
          public.org_seats_wanted(p_org), p_period_end, p_trial_end, not coalesce(p_renews, true), v_grace)
  on conflict (organization_id) do update
    set provider = 'apple',
        apple_original_transaction_id = excluded.apple_original_transaction_id,
        apple_product_id = excluded.apple_product_id,
        apple_environment = excluded.apple_environment,
        apple_signed_at = excluded.apple_signed_at,
        seats_covered = excluded.seats_covered,
        status = excluded.status,
        seats_billed = excluded.seats_billed,
        seats_wanted = excluded.seats_wanted,
        current_period_end = excluded.current_period_end,
        trial_end = excluded.trial_end,
        cancel_at_period_end = excluded.cancel_at_period_end,
        grace_until = excluded.grace_until
  returning * into v_new;

  if v_old.organization_id is null or v_old.status is distinct from v_new.status then
    perform public.activity_add(p_org, 'plan.' || v_new.status, 'company', p_org,
      case v_new.status
        when 'trialing' then 'Started the plan with a free trial, up to ' || v_new.seats_covered || ' people'
        when 'active' then 'The plan is active, up to ' || v_new.seats_covered || ' people'
        when 'past_due' then 'A payment for the plan failed'
        else 'The plan ended' end,
      jsonb_build_object('seats', v_new.seats_covered, 'provider', 'apple'));
  elsif v_old.seats_covered is distinct from v_new.seats_covered then
    perform public.activity_add(p_org, 'plan.seats_changed', 'company', p_org,
      'The plan now covers ' || v_new.seats_covered || ' people, was ' || coalesce(v_old.seats_covered::text, 'none'),
      jsonb_build_object('from', v_old.seats_covered, 'to', v_new.seats_covered));
  end if;

  perform public.org_apply_billing(p_org);
  return jsonb_build_object('organization_id', p_org, 'status', v_new.status, 'seats', v_new.seats_covered,
                            'state', (select state from public.organizations where id = p_org));
end;
$$;

-- Which company owns an Apple subscription, for notifications that arrive without our company id.
create or replace function public.apple_org_for_transaction(p_original_transaction_id text)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select organization_id from public.org_subscriptions where apple_original_transaction_id = p_original_transaction_id;
$$;

-- ---------------------------------------------------------------------------
-- A plan Apple stopped telling us about
-- ---------------------------------------------------------------------------
-- Renewals normally arrive as notifications, and the app also reports its current purchase whenever the Owner opens
-- billing. If a subscription's period ended and nothing has renewed it for a few days, it is treated as ended, so a missed
-- message can't leave a company on a plan nobody is paying for. Run it with the sweep.
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
     where o.state = 'active' and s.provider = 'apple' and s.status in ('trialing', 'active')
       and s.current_period_end is not null
       and s.current_period_end + make_interval(days => public.app_setting_int('billing', 'apple_slack_days', 3)) <= now()
     order by s.organization_id
  loop
    update public.org_subscriptions set status = 'canceled' where organization_id = v_org;
    perform public.activity_add(v_org, 'plan.canceled', 'company', v_org,
      'The plan ended: Apple has not renewed it', jsonb_build_object('provider', 'apple'));
    perform public.org_apply_billing(v_org);
    v_count := v_count + 1;
  end loop;

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
    'seats_billed_by_stripe', case when v_sub.provider = 'stripe' then coalesce(v_sub.seats_billed, 0) else 0 end,
    'provider', coalesce(v_sub.provider, 'stripe'),
    'apple_product_id', v_sub.apple_product_id,
    'apple_environment', v_sub.apple_environment,
    'seats_covered', v_sub.seats_covered,
    'current_period_end', v_sub.current_period_end,
    'trial_end', v_sub.trial_end,
    'cancel_at_period_end', coalesce(v_sub.cancel_at_period_end, false),
    'grace_until', v_sub.grace_until,
    'state', (select state from public.organizations where id = p_org)
  );
end;
$$;

-- "What will happen if I add or remove this many people?" The limit is now the company's own.
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
  v_plan := public.seat_plan(v_used, coalesce(p_delta, 0), public.app_seat_minimum(), public.org_seat_cap(p_org));
  return v_plan || jsonb_build_object(
    'effective', case v_plan ->> 'change' when 'increase' then 'now' when 'decrease' then 'next_invoice' else 'none' end,
    'period_end', v_sub.current_period_end
  );
end;
$$;

-- Everyone in the company can see whether the plan needs attention, now with who it is with and what it covers.
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
      'period_end', v_sub.current_period_end,
      'provider', coalesce(v_sub.provider, 'stripe'),
      'seats_covered', v_sub.seats_covered)
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
-- Recording a plan is for the Edge Functions (the service role) only. The people-limit helpers are internal too.
revoke execute on function
  public.apple_record_subscription(uuid, text, text, text, text, timestamptz, timestamptz, boolean, timestamptz, timestamptz),
  public.apple_org_for_transaction(text),
  public.org_seat_cap(uuid),
  public.org_storage_seats(uuid),
  public.billing_sweep()
from public, anon, authenticated;
-- team_config() is not security definer and calls apple_plan_list(), so the list of products (ids and sizes, nothing secret)
-- is readable like the other settings it returns.
grant execute on function public.apple_plan_list() to anon, authenticated;
