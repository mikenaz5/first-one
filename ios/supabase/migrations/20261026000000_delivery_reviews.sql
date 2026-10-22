-- Slate: delivery and reviews
--
-- After the shoot the creator shares a link to the final files. The client opens it and confirms they have
-- everything; that is what makes the balance payable (payment_prepare refuses it before then). Once the booking
-- is complete (balance paid, or nothing owed), the client can leave one review, which shows on the creator's page.
--
--   share_delivery(booking, url, note)   creator; shoot has started; before the client confirms. Sharing again
--                                        replaces the link (a wrong one can be fixed until the client confirms).
--   confirm_receipt(booking)             client; safe to call twice. Completes the booking when nothing is owed.
--   submit_review(booking, rating, body) client; booking complete and receipt confirmed; once per booking.
--   list_reviews / creator_review_summary   public, for creator pages.
--   get_booking_review(booking)          the creator and the client of that booking.
--
-- The creator's money is never held: Stripe sends the balance straight to the creator when the client pays it
-- (see the payments migration). Confirming receipt only decides *when* the client is asked to pay.
--
-- Errors are plain tokens, as elsewhere: not_signed_in, not_found, not_deliverable, invalid_delivery_url,
-- note_too_long, not_delivered, not_reviewable, invalid_rating, review_too_long, already_reviewed.

-- ---------------------------------------------------------------------------
-- What a delivery link may be. Mirrors DeliveryRules in Swift; delivery_rules.json checks both.
-- ---------------------------------------------------------------------------
-- The cleaned link, or null if it can't be used. Trimmed; https only; at most 2048 characters, all of them from
-- RFC 3986's URI character set (so no spaces, quotes or non-ASCII, and a % only as part of %XX); a real-looking host (dots, a letter in the last
-- part, so no bare IP addresses or "localhost") with an optional port; and no username or password in it.
create or replace function public.delivery_url_clean(p_url text)
returns text
language plpgsql
immutable
as $$
declare
  v_url  text := btrim(coalesce(p_url, ''), E' \n\t\r');
  v_auth text;
begin
  if char_length(v_url) = 0 or char_length(v_url) > 2048 then
    return null;
  end if;
  if v_url !~ '^([]A-Za-z0-9._~:/?#[@!$&''()*+,;=-]|%[0-9A-Fa-f]{2})+$' then
    return null;
  end if;
  if v_url !~* '^https://' then
    return null;
  end if;
  v_auth := (regexp_match(v_url, '^https://([^/?#]*)', 'i'))[1];
  if v_auth is null or v_auth !~* '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9](:[0-9]{1,5})?$' then
    return null;
  end if;
  return v_url;
end;
$$;

-- The note that goes with a delivery.
create or replace function public.delivery_note_max_length()
returns integer
language sql
immutable
as $$ select 500 $$;

-- How a reviewer is named on a public page: "Alex Rivera" shows as "Alex R.". Mirrors ReviewRules in Swift.
create or replace function public.review_display_name(p_name text)
returns text
language sql
immutable
as $$
  with t as (
    select regexp_split_to_array(btrim(coalesce(p_name, ''), E' \n\t\r'), '[ \n\t\r]+') as parts
  )
  select case
    when parts[1] is null or parts[1] = '' then 'Client'
    when cardinality(parts) = 1 then parts[1]
    else parts[1] || ' ' || left(parts[cardinality(parts)], 1) || '.'
  end
  from t
$$;

-- ---------------------------------------------------------------------------
-- bookings: the delivery
-- ---------------------------------------------------------------------------
alter table public.bookings
  add column delivery_url text,
  add column delivery_note text,
  add column receipt_confirmed_at timestamptz;

-- Work delivered under the old "mark as delivered" button had no link and no confirmation step; treat it as
-- confirmed, so a balance that was already payable stays payable.
update public.bookings set receipt_confirmed_at = delivered_at where delivered_at is not null;

alter table public.bookings
  -- (A check passes when its test is null, and the cleaner returns null for a link it refuses; hence the is not distinct from.)
  add constraint bookings_delivery_url_valid check (delivery_url is null or public.delivery_url_clean(delivery_url) is not distinct from delivery_url),
  add constraint bookings_delivery_note_length check (delivery_note is null or char_length(delivery_note) between 1 and 500),
  -- A delivery has a link (older ones are the exception: they were confirmed when this migration ran).
  add constraint bookings_delivered_has_link check (delivered_at is null or delivery_url is not null or receipt_confirmed_at is not null),
  add constraint bookings_receipt_needs_delivery check (receipt_confirmed_at is null or delivered_at is not null);

-- ---------------------------------------------------------------------------
-- The creator shares the final files
-- ---------------------------------------------------------------------------
drop function public.mark_delivered(uuid);

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
  if not found or v_row.creator_id <> v_uid then
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

-- ---------------------------------------------------------------------------
-- The client confirms they have everything
-- ---------------------------------------------------------------------------
-- With a balance to pay this is what makes it payable. With nothing left to pay the booking is complete.
create or replace function public.confirm_receipt(p_booking_id uuid)
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
  if not found or v_row.client_id <> v_uid then
    raise exception 'not_found';
  end if;
  -- Confirming twice (a double tap, a retried request) changes nothing.
  if v_row.receipt_confirmed_at is not null then
    return v_row;
  end if;
  if v_row.status <> 'confirmed' or v_row.delivered_at is null then
    raise exception 'not_delivered';
  end if;

  update public.bookings
     set receipt_confirmed_at = now(),
         status = case when total_cents - deposit_cents <= 0 then 'completed'::public.booking_status else status end
   where id = p_booking_id
  returning * into v_row;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- The balance is payable once the client has confirmed
-- ---------------------------------------------------------------------------
-- Same as in the payments migration, except that the balance now waits for the client's confirmation.
create or replace function public.payment_prepare(p_user_id uuid, p_booking_id uuid, p_kind text, p_fee_bps integer default 0)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b       public.bookings;
  v_acct    public.creator_payment_accounts;
  v_amount  integer;
  v_pay     public.payments;
  v_fee     integer;
begin
  if p_kind not in ('deposit', 'balance') then
    raise exception 'invalid_kind';
  end if;

  select * into v_b from public.bookings where id = p_booking_id;
  if not found or v_b.client_id is distinct from p_user_id then
    raise exception 'not_found';
  end if;
  -- Calendar lock first, then the booking row (see lock_creator_calendar).
  perform public.expire_holds(v_b.creator_id);
  select * into v_b from public.bookings where id = p_booking_id for update;

  if p_kind = 'deposit' then
    if v_b.status = 'expired' then
      raise exception 'hold_expired';
    end if;
    if v_b.status <> 'held' then
      raise exception 'payment_not_due';
    end if;
    v_amount := v_b.deposit_cents;
  else
    if v_b.status <> 'confirmed' or v_b.receipt_confirmed_at is null then
      raise exception 'balance_not_due';
    end if;
    if v_b.deposit_cents > 0 and not exists (
      select 1 from public.payments where booking_id = v_b.id and kind = 'deposit' and status = 'succeeded'
    ) then
      raise exception 'balance_not_due';
    end if;
    v_amount := v_b.total_cents - v_b.deposit_cents;
  end if;

  if v_amount <= 0 then
    raise exception 'nothing_due';
  end if;
  if exists (select 1 from public.payments where booking_id = v_b.id and kind = p_kind::public.payment_kind and status = 'succeeded') then
    raise exception 'already_paid';
  end if;

  select * into v_acct from public.creator_payment_accounts where creator_id = v_b.creator_id;
  if not found or not v_acct.charges_enabled then
    raise exception 'payments_not_ready';
  end if;

  v_fee := (v_amount * greatest(coalesce(p_fee_bps, 0), 0)) / 10000;

  select * into v_pay from public.payments
   where booking_id = v_b.id and kind = p_kind::public.payment_kind and status = 'pending';
  if not found then
    insert into public.payments (booking_id, kind, amount_cents, currency_code, platform_fee_cents, status)
    values (v_b.id, p_kind::public.payment_kind, v_amount, v_b.currency_code, v_fee, 'pending')
    returning * into v_pay;
  end if;

  return jsonb_build_object(
    'payment_id', v_pay.id,
    'booking_id', v_b.id,
    'kind', p_kind,
    'amount_cents', v_pay.amount_cents,
    'currency', lower(v_pay.currency_code),
    'fee_cents', v_pay.platform_fee_cents,
    'destination', v_acct.stripe_account_id,
    'existing_intent', v_pay.stripe_payment_intent_id,
    'description', initcap(p_kind) || ' for ' || v_b.package_name || ' with ' || v_b.creator_name
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Reviews
-- ---------------------------------------------------------------------------
create table public.reviews (
  id            uuid primary key default gen_random_uuid(),
  -- One review per booking.
  booking_id    uuid not null unique references public.bookings (id) on delete cascade,
  creator_id    uuid not null references public.creator_profiles (id) on delete cascade,
  reviewer_id   uuid references auth.users (id) on delete set null,
  -- "Alex R.", worked out when the review is written, so the public page never carries a full name.
  reviewer_name text not null check (char_length(reviewer_name) between 1 and 100),
  package_name  text not null default '',
  rating        smallint not null check (rating between 1 and 5),
  body          text not null default '' check (char_length(body) <= 1000),
  created_at    timestamptz not null default now()
);
create index reviews_creator_idx on public.reviews (creator_id, created_at desc, id);

-- Closed to the API roles: reviews are read and written through the functions below, which decide who sees what.
alter table public.reviews enable row level security;
revoke all on public.reviews from anon, authenticated;

create or replace function public.review_max_length()
returns integer
language sql
immutable
as $$ select 1000 $$;

create or replace function public.submit_review(p_booking_id uuid, p_rating integer, p_body text default '')
returns public.reviews
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_b    public.bookings;
  v_body text;
  v_row  public.reviews;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found or v_b.client_id <> v_uid then
    raise exception 'not_found';
  end if;
  if v_b.status <> 'completed' or v_b.receipt_confirmed_at is null then
    raise exception 'not_reviewable';
  end if;
  if exists (select 1 from public.reviews where booking_id = v_b.id) then
    raise exception 'already_reviewed';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception 'invalid_rating';
  end if;
  v_body := public.message_clean(p_body);
  if char_length(v_body) > public.review_max_length() then
    raise exception 'review_too_long';
  end if;

  insert into public.reviews (booking_id, creator_id, reviewer_id, reviewer_name, package_name, rating, body)
  values (v_b.id, v_b.creator_id, v_uid, public.review_display_name(v_b.client_name), v_b.package_name, p_rating, v_body)
  returning * into v_row;
  return v_row;
end;
$$;

-- The review on one booking, for the two people on it.
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
     and (select auth.uid()) in (b.client_id, b.creator_id)
$$;

-- A creator's reviews, newest first, for their page. Public.
create or replace function public.list_reviews(p_creator_id uuid, p_limit integer default 20, p_before timestamptz default null)
returns table (id uuid, creator_id uuid, rating smallint, body text, reviewer_name text, package_name text, created_at timestamptz)
language sql
stable
security definer
set search_path = public
as $$
  select r.id, r.creator_id, r.rating, r.body, r.reviewer_name, r.package_name, r.created_at
    from public.reviews r
   where r.creator_id = p_creator_id
     and (p_before is null or r.created_at < p_before)
   order by r.created_at desc, r.id desc
   limit greatest(1, least(coalesce(p_limit, 20), 50))
$$;

-- How many reviews and the sum of their ratings; the app works out the average.
create or replace function public.creator_review_summary(p_creator_id uuid)
returns table (review_count integer, rating_sum integer)
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer, coalesce(sum(r.rating), 0)::integer
    from public.reviews r
   where r.creator_id = p_creator_id
$$;

-- ---------------------------------------------------------------------------
-- Conversation lines and notifications
-- ---------------------------------------------------------------------------
-- The old "delivered" line becomes "delivery_shared".
alter table public.messages drop constraint messages_event_check;
update public.messages set event = 'delivery_shared' where event = 'delivered';
alter table public.messages add constraint messages_event_check check (event in (
  'booked', 'contract_signed', 'deposit_paid', 'delivery_shared', 'receipt_confirmed', 'balance_paid', 'reviewed', 'cancelled'));

alter table public.push_outbox drop constraint push_outbox_kind_check;
alter table public.push_outbox add constraint push_outbox_kind_check check (kind in (
  'new_booking', 'booking_cancelled', 'contract_signed', 'payment_received', 'balance_due', 'message', 'shoot_reminder',
  'delivery_shared', 'receipt_confirmed', 'review_received'));

create or replace function public.push_category(p_kind text)
returns text
language sql
immutable
as $$
  select case p_kind
    when 'new_booking' then 'bookings'
    when 'booking_cancelled' then 'bookings'
    when 'delivery_shared' then 'bookings'
    when 'receipt_confirmed' then 'bookings'
    when 'review_received' then 'bookings'
    when 'contract_signed' then 'contracts'
    when 'payment_received' then 'payments'
    when 'balance_due' then 'payments'
    when 'message' then 'messages'
    when 'shoot_reminder' then 'reminders'
  end
$$;

-- The creator shared (or replaced) the link: tell the client.
drop trigger bookings_notify_delivered on public.bookings;

create or replace function public.bookings_notify_delivered()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance integer := greatest(new.total_cents - new.deposit_cents, 0);
  v_revised boolean := old.delivery_url is not null;
begin
  insert into public.messages (booking_id, kind, event, data)
  values (new.id, 'system', 'delivery_shared', jsonb_build_object('revised', v_revised));
  perform public.push_enqueue(new.client_id, 'delivery_shared', new.id, jsonb_build_object(
    'bookingId', new.id, 'role', 'client', 'creatorName', new.creator_name, 'packageName', new.package_name,
    'revised', v_revised, 'balanceCents', v_balance, 'currency', new.currency_code),
    'delivery_shared:' || new.id || ':' || md5(new.delivery_url));
  return null;
end;
$$;

create trigger bookings_notify_delivered
  after update of delivery_url on public.bookings
  for each row
  when (new.delivery_url is not null and new.delivery_url is distinct from old.delivery_url)
  execute function public.bookings_notify_delivered();

-- The client confirmed: tell the creator whether a balance is now on its way.
create or replace function public.bookings_notify_receipt()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance integer := greatest(new.total_cents - new.deposit_cents, 0);
begin
  insert into public.messages (booking_id, kind, event, data)
  values (new.id, 'system', 'receipt_confirmed', jsonb_build_object('balanceCents', v_balance, 'currency', new.currency_code));
  perform public.push_enqueue(new.creator_id, 'receipt_confirmed', new.id, jsonb_build_object(
    'bookingId', new.id, 'role', 'creator', 'clientName', new.client_name, 'packageName', new.package_name,
    'balanceCents', v_balance, 'currency', new.currency_code), 'receipt_confirmed:' || new.id);
  return null;
end;
$$;

create trigger bookings_notify_receipt
  after update of receipt_confirmed_at on public.bookings
  for each row
  when (old.receipt_confirmed_at is null and new.receipt_confirmed_at is not null)
  execute function public.bookings_notify_receipt();

-- A review was left: a line in the conversation and a note to the creator.
create or replace function public.reviews_notify_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.messages (booking_id, kind, event, data)
  values (new.booking_id, 'system', 'reviewed', jsonb_build_object('rating', new.rating));
  perform public.push_enqueue(new.creator_id, 'review_received', new.booking_id, jsonb_build_object(
    'bookingId', new.booking_id, 'role', 'creator', 'reviewerName', new.reviewer_name,
    'packageName', new.package_name, 'rating', new.rating), 'review_received:' || new.id);
  return null;
end;
$$;

create trigger reviews_notify_created
  after insert on public.reviews
  for each row execute function public.reviews_notify_created();

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.bookings_notify_receipt(), public.reviews_notify_created()
  from public, anon, authenticated;

revoke execute on function
  public.share_delivery(uuid, text, text),
  public.confirm_receipt(uuid),
  public.submit_review(uuid, integer, text),
  public.get_booking_review(uuid)
from public, anon;
grant execute on function
  public.share_delivery(uuid, text, text),
  public.confirm_receipt(uuid),
  public.submit_review(uuid, integer, text),
  public.get_booking_review(uuid)
to authenticated;

-- Creator pages are public, and so are their reviews.
grant execute on function
  public.list_reviews(uuid, integer, timestamptz),
  public.creator_review_summary(uuid)
to anon, authenticated;
