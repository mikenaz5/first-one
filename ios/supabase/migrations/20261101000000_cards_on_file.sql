-- Slate Pro: cards on file
--
-- A client can keep cards at Stripe and allow a creator to charge one for the balance of a booking.
--
-- Stripe holds the card. Nothing here can hold a card number, an expiry in full or a security code: these tables keep
-- Stripe's reference to the card, what is needed to show it ("Visa ending 4242, expires 08/28") and who the client has
-- allowed. The reference is closed to the app by column permission, so even the owner's own phone cannot read it.
--
-- A permission (card_grants) belongs to a client and a creator (the owner of the booking: a person, or a company). It
-- can be used for one thing only: the balance of a booking the client has with that creator, and only once that balance
-- is payable (the client has confirmed their files, see payment_prepare). The amount is never chosen by the caller:
-- payment_prepare_saved hands the work to payment_prepare and adds the card to the answer.
--
-- Money is still recorded only from Stripe's signed webhook (payment_record_success). Nothing here marks a payment paid.
--
-- Errors are plain tokens, as elsewhere: not_signed_in, card_not_found, card_expired, consent_outdated,
-- no_booking_with_creator, too_many_cards, unknown_customer, no_card_access, not_found.

-- ---------------------------------------------------------------------------
-- Constants and small rules
-- ---------------------------------------------------------------------------
-- Cards one person can keep. Mirrors CardRules.maxCards in the app.
create or replace function public.app_card_limit()
returns integer
language sql
immutable
as $$ select 5; $$;

-- The version of the wording a client agrees to when they allow a creator (Slate Pro's CardConsent). A permission is
-- only accepted with the current version, so an old copy of the app cannot give consent to text it never showed.
create or replace function public.card_consent_version()
returns integer
language sql
immutable
as $$ select 1; $$;

-- A card works through the last day of its expiry month. Mirrors CardRules.isExpired in the app.
create or replace function public.card_is_expired(p_month integer, p_year integer, p_at timestamptz)
returns boolean
language sql
immutable
as $$
  select (p_year * 12 + p_month)
       < (extract(year from p_at at time zone 'UTC')::integer * 12 + extract(month from p_at at time zone 'UTC')::integer);
$$;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
-- One Stripe customer per person who has saved a card. Service role only.
create table public.client_stripe_customers (
  user_id            uuid primary key references auth.users (id) on delete cascade,
  stripe_customer_id text not null unique,
  created_at         timestamptz not null default now()
);
alter table public.client_stripe_customers enable row level security;
revoke all on public.client_stripe_customers from anon, authenticated;

create table public.client_cards (
  id                       uuid primary key default gen_random_uuid(),
  user_id                  uuid not null references auth.users (id) on delete cascade,
  -- Stripe's reference to the card (pm_…). Never sent to the app.
  stripe_payment_method_id text not null unique,
  -- Stripe's own word for the network, lower case: visa, mastercard, amex, discover, diners, jcb, unionpay, unknown…
  brand                    text not null check (brand ~ '^[a-z_]{1,24}$'),
  last4                    text not null check (last4 ~ '^[0-9]{4}$'),
  exp_month                integer not null check (exp_month between 1 and 12),
  exp_year                 integer not null check (exp_year between 2000 and 2199),
  created_at               timestamptz not null default now()
);
create index client_cards_user_idx on public.client_cards (user_id, created_at, id);

alter table public.client_cards enable row level security;
-- Written only by the card_* functions below, which run for the service role. A person reads their own cards, and only
-- the columns that are shown; asking for stripe_payment_method_id (or for every column) is refused.
revoke all on public.client_cards from anon, authenticated;
grant select (id, user_id, brand, last4, exp_month, exp_year, created_at) on public.client_cards to authenticated;
create policy "People see their own cards"
  on public.client_cards for select
  to authenticated
  using ((select auth.uid()) = user_id);

-- Who a client has allowed. One row for each client and creator.
create table public.card_grants (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references auth.users (id) on delete cascade,
  -- The owner of the bookings: a person's profile, or a company's.
  creator_id      uuid not null references public.creator_profiles (id) on delete cascade,
  card_id         uuid not null references public.client_cards (id) on delete cascade,
  consent_version integer not null,
  granted_at      timestamptz not null default now(),
  unique (client_id, creator_id)
);
create index card_grants_card_idx on public.card_grants (card_id);

alter table public.card_grants enable row level security;
revoke all on public.card_grants from anon, authenticated;
grant select on public.card_grants to authenticated;
-- Creators do not read this table. They are told whether the booking in front of them has a permission, by
-- card_access_for_booking, and nothing more.
create policy "Clients see who they have allowed"
  on public.card_grants for select
  to authenticated
  using ((select auth.uid()) = client_id);

-- When a client allowed a creator and when they stopped it. Append only, for the client's own record and to show when an
-- agreement was given if a charge is ever disputed. It goes with the account.
create table public.card_grant_log (
  id              bigint generated always as identity primary key,
  client_id       uuid not null references auth.users (id) on delete cascade,
  creator_id      uuid not null,
  card_brand      text,
  card_last4      text,
  action          text not null check (action in ('allowed', 'stopped', 'card_removed')),
  consent_version integer,
  at              timestamptz not null default now()
);
create index card_grant_log_client_idx on public.card_grant_log (client_id, at desc);

alter table public.card_grant_log enable row level security;
revoke all on public.card_grant_log from anon, authenticated;
grant select on public.card_grant_log to authenticated;
create policy "Clients see their own record"
  on public.card_grant_log for select
  to authenticated
  using ((select auth.uid()) = client_id);

-- ---------------------------------------------------------------------------
-- What the app calls (a signed-in person, for themselves)
-- ---------------------------------------------------------------------------
-- Allows a creator to charge the balance of this person's bookings with them to one of their cards. Allowing again,
-- with another card, replaces the first. Only a creator the person has booked, only the person's own card.
create or replace function public.card_grant(p_creator_id uuid, p_card_id uuid, p_consent_version integer)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_card public.client_cards;
  v_id   uuid;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  if p_consent_version is distinct from public.card_consent_version() then
    raise exception 'consent_outdated';
  end if;
  select * into v_card from public.client_cards where id = p_card_id and user_id = v_uid;
  if not found then
    raise exception 'card_not_found';
  end if;
  if public.card_is_expired(v_card.exp_month, v_card.exp_year, now()) then
    raise exception 'card_expired';
  end if;
  if not exists (
    select 1 from public.bookings b
     where b.client_id = v_uid and b.creator_id = p_creator_id and b.status in ('held', 'confirmed', 'completed')
  ) then
    raise exception 'no_booking_with_creator';
  end if;

  insert into public.card_grants (client_id, creator_id, card_id, consent_version)
  values (v_uid, p_creator_id, p_card_id, p_consent_version)
  on conflict (client_id, creator_id)
  do update set card_id = excluded.card_id, consent_version = excluded.consent_version, granted_at = now()
  returning id into v_id;

  insert into public.card_grant_log (client_id, creator_id, card_brand, card_last4, action, consent_version)
  values (v_uid, p_creator_id, v_card.brand, v_card.last4, 'allowed', p_consent_version);
  return v_id;
end;
$$;

-- Stops it, at once and without asking anyone. True when there was something to stop.
create or replace function public.card_revoke(p_creator_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_grant public.card_grants;
  v_card  public.client_cards;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  delete from public.card_grants where client_id = v_uid and creator_id = p_creator_id returning * into v_grant;
  if not found then
    return false;
  end if;
  select * into v_card from public.client_cards where id = v_grant.card_id;
  insert into public.card_grant_log (client_id, creator_id, card_brand, card_last4, action, consent_version)
  values (v_uid, p_creator_id, v_card.brand, v_card.last4, 'stopped', v_grant.consent_version);
  return true;
end;
$$;

-- The creators this person has allowed, with the card each may use. Newest first.
create or replace function public.my_card_grants()
returns table (
  creator_id uuid, creator_name text, handle text, avatar_path text,
  card_id uuid, brand text, last4 text, exp_month integer, exp_year integer, granted_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  select g.creator_id, p.display_name, p.handle, p.avatar_path,
         c.id, c.brand, c.last4, c.exp_month, c.exp_year, g.granted_at
    from public.card_grants g
    join public.client_cards c on c.id = g.card_id
    join public.creator_profiles p on p.id = g.creator_id
   where g.client_id = auth.uid()
   order by g.granted_at desc, g.id;
$$;

-- What the person in front of a booking may know about its saved-card permission.
--   The client: whether they have allowed this creator, and with which card (brand and last four).
--   The provider side (anyone who can see the booking): whether there is a permission, the card's brand and whether it
--   has expired. Never the last four, and never anything Stripe holds.
create or replace function public.card_access_for_booking(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_b      public.bookings;
  v_client boolean;
  v_card   public.client_cards;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_b from public.bookings where id = p_booking_id;
  v_client := found and v_b.client_id = v_uid;
  if not found or not (v_client or public.provider_access(v_uid, v_b.creator_id, v_b.assigned_to, 'view')) then
    raise exception 'not_found';
  end if;

  select c.* into v_card
    from public.card_grants g join public.client_cards c on c.id = g.card_id
   where g.client_id = v_b.client_id and g.creator_id = v_b.creator_id;
  if not found then
    return jsonb_build_object('allowed', false, 'brand', null, 'last4', null, 'expired', false);
  end if;
  return jsonb_build_object(
    'allowed', true,
    'brand', v_card.brand,
    'last4', case when v_client then v_card.last4 end,
    'expired', public.card_is_expired(v_card.exp_month, v_card.exp_year, now())
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- What the Edge Functions call (service role only)
-- ---------------------------------------------------------------------------
create or replace function public.card_customer_for(p_user uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select stripe_customer_id from public.client_stripe_customers where user_id = p_user;
$$;

create or replace function public.card_customer_save(p_user uuid, p_customer_id text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.client_stripe_customers (user_id, stripe_customer_id)
  values (p_user, p_customer_id)
  on conflict (user_id) do nothing;
$$;

-- Before Stripe's page is opened: which customer to use (null when there is none yet), and whether there is room.
create or replace function public.card_prepare(p_user uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  select count(*) into v_count from public.client_cards where user_id = p_user;
  if v_count >= public.app_card_limit() then
    raise exception 'too_many_cards';
  end if;
  return jsonb_build_object('customer_id', public.card_customer_for(p_user), 'card_count', v_count);
end;
$$;

-- Stripe says a card was saved (or what it knows about one has changed). Safe to call twice.
create or replace function public.card_record(
  p_customer_id text, p_payment_method_id text, p_brand text, p_last4 text, p_exp_month integer, p_exp_year integer
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  v_id   uuid;
begin
  select user_id into v_user from public.client_stripe_customers where stripe_customer_id = p_customer_id;
  if not found then
    raise exception 'unknown_customer';
  end if;
  insert into public.client_cards (user_id, stripe_payment_method_id, brand, last4, exp_month, exp_year)
  values (v_user, p_payment_method_id, lower(coalesce(nullif(btrim(p_brand), ''), 'unknown')), p_last4, p_exp_month, p_exp_year)
  on conflict (stripe_payment_method_id)
  do update set brand = excluded.brand, last4 = excluded.last4, exp_month = excluded.exp_month, exp_year = excluded.exp_year
  where client_cards.user_id = excluded.user_id
  returning id into v_id;
  return v_id;
end;
$$;

-- Stripe's reference to one of this person's cards, so it can be removed there first.
create or replace function public.card_lookup(p_user uuid, p_card_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_pm text;
begin
  select stripe_payment_method_id into v_pm from public.client_cards where id = p_card_id and user_id = p_user;
  if not found then
    raise exception 'card_not_found';
  end if;
  return v_pm;
end;
$$;

-- The card is gone from Stripe: forget it here, and with it every permission that used it. The record says so.
create or replace function public.card_forget(p_user uuid, p_card_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.card_grant_log (client_id, creator_id, card_brand, card_last4, action, consent_version)
  select g.client_id, g.creator_id, c.brand, c.last4, 'card_removed', g.consent_version
    from public.card_grants g join public.client_cards c on c.id = g.card_id
   where g.card_id = p_card_id and c.user_id = p_user;
  delete from public.client_cards where id = p_card_id and user_id = p_user;
end;
$$;

-- Stripe says a card was removed on its side (the customer's page, the dashboard, a bank closing it): the same, by
-- Stripe's reference. Nothing happens for a card we never had.
create or replace function public.card_forget_method(p_payment_method_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  v_card uuid;
begin
  select user_id, id into v_user, v_card from public.client_cards where stripe_payment_method_id = p_payment_method_id;
  if found then
    perform public.card_forget(v_user, v_card);
  end if;
end;
$$;

-- After comparing with Stripe's list: forget every card of this person that Stripe no longer has. Returns how many.
create or replace function public.card_prune(p_user uuid, p_keep text[])
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_card  uuid;
  v_count integer := 0;
begin
  for v_card in
    select id from public.client_cards
     where user_id = p_user and not (stripe_payment_method_id = any (coalesce(p_keep, '{}'::text[])))
     order by created_at, id
  loop
    perform public.card_forget(p_user, v_card);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- A creator (or whoever can manage the booking) asks to charge the balance to the client's saved card. The work of
-- deciding what is owed, and whether it is payable, is payment_prepare's: this adds who may ask and which card.
--   not_found       the person asking has no say over this booking
--   no_card_access  the client has not allowed this creator, or the card is not there to use
--   card_expired    the card has passed its expiry month
-- plus everything payment_prepare says: balance_not_due, nothing_due, already_paid, payments_not_ready.
create or replace function public.payment_prepare_saved(p_actor uuid, p_booking_id uuid, p_fee_bps integer default 0)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b    public.bookings;
  v_card public.client_cards;
  v_cust text;
  v_prep jsonb;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  if not found or not public.provider_access(p_actor, v_b.creator_id, v_b.assigned_to, 'manage') then
    raise exception 'not_found';
  end if;

  select c.* into v_card
    from public.card_grants g join public.client_cards c on c.id = g.card_id
   where g.client_id = v_b.client_id and g.creator_id = v_b.creator_id;
  select stripe_customer_id into v_cust from public.client_stripe_customers where user_id = v_b.client_id;
  if v_card.id is null or v_cust is null then
    raise exception 'no_card_access';
  end if;
  if public.card_is_expired(v_card.exp_month, v_card.exp_year, now()) then
    raise exception 'card_expired';
  end if;

  v_prep := public.payment_prepare(v_b.client_id, p_booking_id, 'balance', p_fee_bps);
  -- It is a card payment, whichever way it ends.
  update public.payments set method = 'card'
   where id = (v_prep ->> 'payment_id')::uuid and status = 'pending' and stripe_payment_intent_id is null;
  return v_prep || jsonb_build_object('customer', v_cust, 'payment_method', v_card.stripe_payment_method_id);
end;
$$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function
  public.card_customer_for(uuid),
  public.card_customer_save(uuid, text),
  public.card_prepare(uuid),
  public.card_record(text, text, text, text, integer, integer),
  public.card_lookup(uuid, uuid),
  public.card_forget(uuid, uuid),
  public.card_forget_method(text),
  public.card_prune(uuid, text[]),
  public.payment_prepare_saved(uuid, uuid, integer)
from public, anon, authenticated;

revoke execute on function
  public.card_grant(uuid, uuid, integer),
  public.card_revoke(uuid),
  public.my_card_grants(),
  public.card_access_for_booking(uuid)
from public, anon;
grant execute on function
  public.card_grant(uuid, uuid, integer),
  public.card_revoke(uuid),
  public.my_card_grants(),
  public.card_access_for_booking(uuid)
to authenticated;
