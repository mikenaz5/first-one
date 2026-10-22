-- Slate: payments
--
-- A booking with a deposit is first *held* for a few minutes. It becomes confirmed, and its contract
-- executed, only when the deposit has actually been paid. The balance is paid after delivery. Cancelling
-- works out the refund from the cancellation policy the client agreed to.
--
-- Money moves in Stripe, never here. These tables are a ledger of what Stripe has told us, written only
-- by the payment functions (called from Edge Functions with the service role). The app can read its own
-- bookings' payments and nothing else.
--
-- Errors are plain tokens, as elsewhere: payments_not_ready, hold_expired, payment_not_due, balance_not_due,
-- nothing_due, already_paid, not_found, invalid_kind, amount_mismatch, unknown_payment, not_deliverable.

-- ---------------------------------------------------------------------------
-- Constants and small rules
-- ---------------------------------------------------------------------------
create or replace function public.app_hold_minutes()
returns integer
language sql
immutable
as $$ select 15; $$;

-- Share of what was paid that a *client's* cancellation returns. Mirrors CancellationPolicy.refundPercent in the app.
create or replace function public.refund_percent(p_policy text, p_hours_before numeric)
returns integer
language sql
immutable
as $$
  select case p_policy
    when 'flexible' then case when greatest(0, p_hours_before) >= 24 then 100 else 50 end
    when 'moderate' then case when greatest(0, p_hours_before) >= 168 then 100
                              when greatest(0, p_hours_before) >= 48 then 50
                              else 0 end
    when 'strict'   then case when greatest(0, p_hours_before) >= 336 then 50 else 0 end
    else 0
  end;
$$;

-- ---------------------------------------------------------------------------
-- bookings: what payments need to remember
-- ---------------------------------------------------------------------------
alter table public.bookings
  -- The policy the client agreed to, snapshotted so later package edits can't change a refund.
  add column cancellation_policy text not null default 'moderate' check (cancellation_policy in ('flexible', 'moderate', 'strict')),
  add column hold_expires_at timestamptz,
  add column delivered_at timestamptz,
  add column cancelled_at timestamptz,
  add column cancelled_by uuid references auth.users (id) on delete set null,
  add constraint bookings_held_has_expiry check (status <> 'held' or hold_expires_at is not null);

-- ---------------------------------------------------------------------------
-- Stripe Connect accounts (one per creator)
-- ---------------------------------------------------------------------------
create table public.creator_payment_accounts (
  creator_id        uuid primary key references public.creator_profiles (id) on delete cascade,
  stripe_account_id text not null unique,
  charges_enabled   boolean not null default false,
  payouts_enabled   boolean not null default false,
  details_submitted boolean not null default false,
  updated_at        timestamptz not null default now()
);

alter table public.creator_payment_accounts enable row level security;

-- Written only by the connect_* functions, from the Stripe webhook.
create policy "Creators read their own payment account"
  on public.creator_payment_accounts for select
  to authenticated
  using ((select auth.uid()) = creator_id);

-- ---------------------------------------------------------------------------
-- payments: the ledger
-- ---------------------------------------------------------------------------
create type public.payment_kind as enum ('deposit', 'balance', 'refund');
create type public.payment_status as enum ('pending', 'succeeded', 'failed', 'canceled');

create table public.payments (
  id                       uuid primary key default gen_random_uuid(),
  booking_id               uuid not null references public.bookings (id) on delete cascade,
  kind                     public.payment_kind not null,
  -- A refund points at the payment it returns money from.
  refund_of                uuid references public.payments (id),
  amount_cents             integer not null check (amount_cents > 0),
  currency_code            text not null,
  platform_fee_cents       integer not null default 0 check (platform_fee_cents >= 0),
  status                   public.payment_status not null default 'pending',
  method                   text check (method in ('apple_pay', 'card', 'simulated')),
  stripe_payment_intent_id text unique,
  stripe_charge_id         text,
  stripe_refund_id         text unique,
  failure_message          text,
  created_at               timestamptz not null default now(),
  -- When a payment succeeded, or a refund was issued.
  paid_at                  timestamptz,
  constraint payments_refund_points_at_payment check ((kind = 'refund') = (refund_of is not null))
);

-- One live deposit and one live balance per booking. A failed or cancelled attempt doesn't count, so people can retry.
create unique index payments_one_live_per_kind
  on public.payments (booking_id, kind)
  where kind in ('deposit', 'balance') and status in ('pending', 'succeeded');
create index payments_booking_idx on public.payments (booking_id);

alter table public.payments enable row level security;

create policy "People see the payments on their bookings"
  on public.payments for select
  to authenticated
  using (exists (
    select 1 from public.bookings b
     where b.id = booking_id
       and ((select auth.uid()) = b.client_id or (select auth.uid()) = b.creator_id)
  ));

-- Stripe sends each event at least once. This remembers which ones were handled.
create table public.stripe_events (
  id           text primary key,
  type         text not null,
  received_at  timestamptz not null default now(),
  processed_at timestamptz
);
alter table public.stripe_events enable row level security;

-- ---------------------------------------------------------------------------
-- Holds
-- ---------------------------------------------------------------------------
-- One creator's bookings are changed one transaction at a time. Two clients booking overlapping times at the
-- same moment would otherwise each wait on the other's uncommitted row while the exclusion constraint checks
-- them, and Postgres would break the tie with a deadlock error instead of a clean "slot taken". Everything that
-- can add to or revive a creator's active bookings takes this lock *before* any row lock, so the order is always
-- the same and can't deadlock.
create or replace function public.lock_creator_calendar(p_creator_id uuid)
returns void
language sql
as $$
  select pg_advisory_xact_lock(hashtextextended('slate:calendar:' || p_creator_id::text, 0));
$$;

-- Gives up bookings whose deposit wasn't paid in time: the time is freed, the unsigned-off contract voided.
-- Safe for anyone to run; it only touches holds that have already lapsed.
create or replace function public.expire_holds(p_creator_id uuid default null)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids     uuid[];
  v_creator uuid;
  v_count   integer := 0;
begin
  if p_creator_id is null then
    -- Every creator with a lapsed hold, always in the same order.
    for v_creator in
      select distinct creator_id from public.bookings
       where status = 'held' and hold_expires_at <= now()
       order by creator_id
    loop
      v_count := v_count + public.expire_holds(v_creator);
    end loop;
    return v_count;
  end if;

  perform public.lock_creator_calendar(p_creator_id);
  with lapsed as (
    update public.bookings
       set status = 'expired'
     where status = 'held'
       and hold_expires_at <= now()
       and creator_id = p_creator_id
    returning id
  )
  select coalesce(array_agg(id), '{}'::uuid[]) into v_ids from lapsed;

  if cardinality(v_ids) = 0 then
    return 0;
  end if;
  update public.contracts set status = 'voided' where booking_id = any (v_ids) and status = 'pending';
  update public.payments set status = 'canceled' where booking_id = any (v_ids) and status = 'pending' and kind <> 'refund';
  return cardinality(v_ids);
end;
$$;

-- ---------------------------------------------------------------------------
-- Making a booking
-- ---------------------------------------------------------------------------
-- A creator can take a deposit only once Stripe says their account can accept charges.
create or replace function public.assert_payments_ready(p_package_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pkg public.packages;
begin
  select * into v_pkg from public.packages where id = p_package_id;
  if found and v_pkg.deposit_cents > 0 and not exists (
    select 1 from public.creator_payment_accounts a where a.creator_id = v_pkg.creator_id and a.charges_enabled
  ) then
    raise exception 'payments_not_ready';
  end if;
end;
$$;

-- Adds the creator's saved signature and finishes the contract. Used when the deposit is paid (or none is due).
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
  select * into v_sig from public.creator_signatures where creator_id = v_contract.creator_id;
  if not found then
    raise exception 'creator_not_ready';
  end if;

  insert into public.contract_signatures (contract_id, role, user_id, signed_name, method, image_png, consent_version, device, ip)
  values (v_contract.id, 'creator', v_contract.creator_id, v_sig.signed_name, 'onFile',
          case when v_sig.method = 'drawn' then v_sig.image_png end,
          1, 'Signature on file, applied when the booking was confirmed', null)
  on conflict (contract_id, role) do nothing;

  update public.contracts set status = 'executed', executed_at = now() where id = v_contract.id;
end;
$$;

-- The previous preview, plus the check that the creator can be paid.
create or replace function public.preview_contract(
  p_package_id   uuid,
  p_add_on_ids   uuid[],
  p_start_at     timestamptz,
  p_client_name  text default '',
  p_notes        text default ''
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prep jsonb := public.contract_prepare(p_package_id, p_add_on_ids, p_start_at, p_client_name, p_notes);
begin
  perform public.assert_payments_ready(p_package_id);
  return v_prep -> 'rendered';
end;
$$;

-- create_booking v3. Book and sign in one step, as before; now a booking with a deposit is *held* for a few
-- minutes with its contract pending (signed by the client only), and a booking with no deposit is confirmed at once.
create or replace function public.create_booking(
  p_package_id    uuid,
  p_add_on_ids    uuid[],
  p_start_at      timestamptz,
  p_client_name   text,
  p_notes         text,
  p_document_hash text,
  p_signature     jsonb
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
  v_creator_sig   public.creator_signatures;
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
begin
  v_prep := public.contract_prepare(p_package_id, p_add_on_ids, p_start_at, p_client_name, p_notes);
  v_rendered := v_prep -> 'rendered';
  v_chosen := v_prep -> 'chosen';

  perform public.assert_payments_ready(p_package_id);
  -- Holds that lapsed must stop blocking the calendar before we look at it.
  perform public.expire_holds((v_prep ->> 'creator_id')::uuid);

  select * into v_pkg from public.packages where id = p_package_id;
  select * into v_settings from public.availability_settings where creator_id = v_pkg.creator_id;

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
    select 1 from jsonb_array_elements(v_settings.blackouts) as b
     where v_day between (b ->> 'start')::date and (b ->> 'end')::date
  ) then
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
      creator_id, client_id, creator_name, client_name, package_id, package_name, add_ons,
      start_at, end_at, blocked_until, time_zone, currency_code, total_cents, deposit_cents,
      status, hold_expires_at, cancellation_policy, notes
    ) values (
      v_pkg.creator_id, v_uid, v_prep ->> 'creator_name', left(coalesce(p_client_name, ''), 80),
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
    booking_id, creator_id, client_id, template_id, template_version, title, sections, document_hash, status, executed_at
  ) values (
    v_booking.id, v_pkg.creator_id, v_uid, (v_rendered ->> 'template_id')::uuid, (v_rendered ->> 'template_version')::integer,
    v_rendered ->> 'title', v_rendered -> 'sections', v_rendered ->> 'document_hash',
    'pending', null
  )
  returning * into v_contract;

  insert into public.contract_signatures (contract_id, role, user_id, signed_name, method, image_png, consent_version, device, ip)
  values (v_contract.id, 'client', v_uid, v_sig_name, v_sig_method,
          case when v_sig_method = 'drawn' then v_sig_image end,
          coalesce((p_signature ->> 'consentVersion')::integer, 1), left(coalesce(p_signature ->> 'device', ''), 200), v_ip);

  -- With a deposit the creator's signature is added when it is paid; with none, the contract is complete now.
  if not v_held then
    perform public.contract_execute(v_booking.id);
  end if;

  return jsonb_build_object('booking', to_jsonb(v_booking), 'contract', public.contract_json(v_contract.id));
end;
$$;

-- Lapsed holds don't block the calendar, even before expire_holds has tidied them up.
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
     and (b.status = 'confirmed' or (b.status = 'held' and b.hold_expires_at > now()))
     and tstzrange(b.start_at, b.blocked_until, '[)') && tstzrange(p_from, p_to, '[)')
  union all
  select bb.starts_at, bb.ends_at, 'external'::text
    from public.busy_blocks bb
   where bb.creator_id = p_creator_id
     and tstzrange(bb.starts_at, bb.ends_at, '[)') && tstzrange(p_from, p_to, '[)');
$$;

-- ---------------------------------------------------------------------------
-- Cancelling and refunds
-- ---------------------------------------------------------------------------
-- What a cancellation would return, as of now. Internal: callers check who is asking first.
create or replace function public.booking_refund_figures(p_booking_id uuid, p_by_creator boolean)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_b        public.bookings;
  v_paid     integer;
  v_refunded integer;
  v_hours    numeric;
  v_percent  integer;
  v_held     integer;
begin
  select * into v_b from public.bookings where id = p_booking_id;
  select coalesce(sum(amount_cents), 0) into v_paid
    from public.payments where booking_id = p_booking_id and kind in ('deposit', 'balance') and status = 'succeeded';
  select coalesce(sum(amount_cents), 0) into v_refunded
    from public.payments where booking_id = p_booking_id and kind = 'refund' and status in ('pending', 'succeeded');

  v_held := v_paid - v_refunded;
  v_hours := extract(epoch from (v_b.start_at - now())) / 3600.0;
  -- If the creator cancels, the client always gets everything back.
  v_percent := case when p_by_creator then 100 else public.refund_percent(v_b.cancellation_policy, v_hours) end;

  return jsonb_build_object(
    'paid_cents', v_held,
    'percent', v_percent,
    'refund_cents', (v_held * v_percent) / 100,
    'hours_before', round(v_hours, 2),
    'policy', v_b.cancellation_policy,
    'by_creator', p_by_creator,
    'currency', v_b.currency_code
  );
end;
$$;

-- The exact refund the person asking would cause by cancelling now, shown before they confirm.
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
     or (v_b.client_id is distinct from v_uid and v_b.creator_id <> v_uid)
     or v_b.status not in ('held', 'confirmed')
     or v_b.start_at <= now() then
    raise exception 'not_cancellable';
  end if;
  return public.booking_refund_figures(p_booking_id, v_uid = v_b.creator_id);
end;
$$;

-- Was `returns bookings`; now says what is owed back too. Refunds are recorded here as pending and
-- carried out in Stripe by the process-refunds function, so cancelling never loses a refund.
drop function public.cancel_booking(uuid);

create function public.cancel_booking(p_booking_id uuid)
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
     or (v_row.client_id is distinct from v_uid and v_row.creator_id <> v_uid)
     or v_row.status not in ('held', 'confirmed')
     or v_row.start_at <= now() then
    raise exception 'not_cancellable';
  end if;

  v_by_creator := v_uid = v_row.creator_id;
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

-- ---------------------------------------------------------------------------
-- After the shoot
-- ---------------------------------------------------------------------------
-- The creator says the work has been delivered, which makes the balance payable. With nothing left to pay
-- the booking is complete straight away.
create or replace function public.mark_delivered(p_booking_id uuid)
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
  if not found or v_row.creator_id <> v_uid then
    raise exception 'not_found';
  end if;
  if v_row.status <> 'confirmed' or v_row.delivered_at is not null or v_row.start_at > now() then
    raise exception 'not_deliverable';
  end if;

  update public.bookings
     set delivered_at = now(),
         status = case when total_cents - deposit_cents <= 0 then 'completed'::public.booking_status else status end
   where id = p_booking_id
  returning * into v_row;
  return v_row;
end;
$$;

-- ---------------------------------------------------------------------------
-- Functions for the Edge Functions (service role only)
-- ---------------------------------------------------------------------------
-- Works out what is owed and opens (or reuses) the pending payment row. The amount comes from the
-- booking, never from the caller.
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
    if v_b.status <> 'confirmed' or v_b.delivered_at is null then
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

create or replace function public.payment_attach_intent(p_payment_id uuid, p_intent_id text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.payments
     set stripe_payment_intent_id = p_intent_id, method = coalesce(method, 'apple_pay')
   where id = p_payment_id and stripe_payment_intent_id is null;
$$;

-- Stripe says a payment went through. Safe to call twice. Returns what the caller must do next:
--   confirmed / completed / noop, or refund_required (the money arrived too late or for a cancelled booking).
create or replace function public.payment_record_success(p_intent_id text, p_amount_cents integer, p_charge_id text default null, p_method text default 'apple_pay')
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking_id uuid;
  v_creator_id uuid;
  v_b          public.bookings;
  v_pay        public.payments;
  v_refund_id  uuid;
begin
  select p.booking_id, b.creator_id into v_booking_id, v_creator_id
    from public.payments p join public.bookings b on b.id = p.booking_id
   where p.stripe_payment_intent_id = p_intent_id;
  if not found then
    raise exception 'unknown_payment';
  end if;
  -- The calendar lock first (this may put a booking back on the calendar), then the booking, then its payments:
  -- the same order everywhere, so it can't deadlock with creating or cancelling a booking.
  perform public.lock_creator_calendar(v_creator_id);
  select * into v_b from public.bookings where id = v_booking_id for update;
  select * into v_pay from public.payments where stripe_payment_intent_id = p_intent_id for update;

  if v_pay.status = 'succeeded' then
    return jsonb_build_object('action', 'noop', 'booking_id', v_b.id, 'payment_id', v_pay.id);
  end if;
  if p_amount_cents is distinct from v_pay.amount_cents then
    raise exception 'amount_mismatch';
  end if;

  -- Two attempts both went through for the same thing: keep the first and give this one straight back.
  if exists (
    select 1 from public.payments
     where booking_id = v_b.id and kind = v_pay.kind and status = 'succeeded' and id <> v_pay.id
  ) then
    update public.payments
       set status = 'canceled', paid_at = now(), stripe_charge_id = coalesce(p_charge_id, stripe_charge_id),
           method = coalesce(p_method, method), failure_message = 'Duplicate payment'
     where id = v_pay.id;
    insert into public.payments (booking_id, kind, refund_of, amount_cents, currency_code, status, method)
    values (v_b.id, 'refund', v_pay.id, v_pay.amount_cents, v_pay.currency_code, 'pending', coalesce(p_method, v_pay.method))
    returning id into v_refund_id;
    return jsonb_build_object('action', 'refund_required', 'booking_id', v_b.id, 'payment_id', v_pay.id, 'refund_id', v_refund_id);
  end if;
  -- Any other attempt still waiting for the same thing is moot now.
  update public.payments set status = 'canceled'
   where booking_id = v_b.id and kind = v_pay.kind and status = 'pending' and id <> v_pay.id;

  update public.payments
     set status = 'succeeded', paid_at = now(), stripe_charge_id = coalesce(p_charge_id, stripe_charge_id),
         method = coalesce(p_method, method), failure_message = null
   where id = v_pay.id;

  if v_pay.kind = 'deposit' then
    if v_b.status = 'held' then
      update public.bookings set status = 'confirmed', hold_expires_at = null where id = v_b.id;
      perform public.contract_execute(v_b.id);
      return jsonb_build_object('action', 'confirmed', 'booking_id', v_b.id, 'payment_id', v_pay.id);
    elsif v_b.status = 'expired' then
      -- Paid after the hold lapsed. If nobody has taken the time, honour it.
      begin
        update public.bookings set status = 'confirmed', hold_expires_at = null where id = v_b.id;
        perform public.contract_execute(v_b.id);
        return jsonb_build_object('action', 'confirmed', 'booking_id', v_b.id, 'payment_id', v_pay.id);
      exception
        when exclusion_violation then
          null; -- Taken in the meantime: fall through to a refund.
      end;
    elsif v_b.status in ('confirmed', 'completed') then
      return jsonb_build_object('action', 'noop', 'booking_id', v_b.id, 'payment_id', v_pay.id);
    end if;
  else
    if v_b.status = 'confirmed' then
      update public.bookings set status = 'completed' where id = v_b.id;
      return jsonb_build_object('action', 'completed', 'booking_id', v_b.id, 'payment_id', v_pay.id);
    elsif v_b.status = 'completed' then
      return jsonb_build_object('action', 'noop', 'booking_id', v_b.id, 'payment_id', v_pay.id);
    end if;
  end if;

  -- The booking was cancelled (or its time was taken) while this was being paid: give it all back.
  insert into public.payments (booking_id, kind, refund_of, amount_cents, currency_code, status, method)
  values (v_b.id, 'refund', v_pay.id, v_pay.amount_cents, v_pay.currency_code, 'pending', coalesce(p_method, v_pay.method))
  returning id into v_refund_id;
  return jsonb_build_object('action', 'refund_required', 'booking_id', v_b.id, 'payment_id', v_pay.id, 'refund_id', v_refund_id);
end;
$$;

create or replace function public.payment_record_failure(p_intent_id text, p_message text default null)
returns void
language sql
security definer
set search_path = public
as $$
  update public.payments
     set status = 'failed', failure_message = left(p_message, 300)
   where stripe_payment_intent_id = p_intent_id and status = 'pending';
$$;

-- Refunds that still have to be sent to Stripe for one booking.
create or replace function public.refunds_to_process(p_booking_id uuid)
returns table (refund_id uuid, amount_cents integer, payment_intent_id text, stripe_refund_id text)
language sql
stable
security definer
set search_path = public
as $$
  select r.id, r.amount_cents, p.stripe_payment_intent_id, r.stripe_refund_id
    from public.payments r
    join public.payments p on p.id = r.refund_of
   where r.booking_id = p_booking_id and r.kind = 'refund' and r.status = 'pending'
   order by r.created_at;
$$;

create or replace function public.refund_record_result(p_refund_id uuid, p_status text, p_stripe_refund_id text default null, p_message text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_status not in ('pending', 'succeeded', 'failed') then
    raise exception 'invalid_kind';
  end if;
  update public.payments
     set status = p_status::public.payment_status,
         stripe_refund_id = coalesce(p_stripe_refund_id, stripe_refund_id),
         paid_at = case when p_status = 'succeeded' then coalesce(paid_at, now()) else paid_at end,
         failure_message = left(p_message, 300)
   where id = p_refund_id and kind = 'refund' and status <> 'succeeded';
end;
$$;

-- Stripe reports a refund by its own id: find the row it belongs to.
create or replace function public.refund_record_by_stripe_id(p_stripe_refund_id text, p_status text, p_message text default null)
returns void
language sql
security definer
set search_path = public
as $$
  update public.payments
     set status = p_status::public.payment_status,
         paid_at = case when p_status = 'succeeded' then coalesce(paid_at, now()) else paid_at end,
         failure_message = left(p_message, 300)
   where stripe_refund_id = p_stripe_refund_id and kind = 'refund' and status <> 'succeeded'
     and p_status in ('pending', 'succeeded', 'failed');
$$;

create or replace function public.is_booking_party(p_user_id uuid, p_booking_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.bookings b
     where b.id = p_booking_id and (b.client_id = p_user_id or b.creator_id = p_user_id)
  );
$$;

-- Stripe Connect accounts.
create or replace function public.connect_account_for(p_creator_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select stripe_account_id from public.creator_payment_accounts where creator_id = p_creator_id;
$$;

create or replace function public.connect_account_save(p_creator_id uuid, p_account_id text)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.creator_payment_accounts (creator_id, stripe_account_id)
  values (p_creator_id, p_account_id)
  on conflict (creator_id) do nothing;
$$;

create or replace function public.connect_account_update(p_account_id text, p_charges boolean, p_payouts boolean, p_details boolean)
returns void
language sql
security definer
set search_path = public
as $$
  update public.creator_payment_accounts
     set charges_enabled = coalesce(p_charges, false), payouts_enabled = coalesce(p_payouts, false),
         details_submitted = coalesce(p_details, false), updated_at = now()
   where stripe_account_id = p_account_id;
$$;

-- Webhook de-duplication: true means "go ahead and handle this event".
create or replace function public.webhook_claim_event(p_event_id text, p_type text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_done timestamptz;
begin
  insert into public.stripe_events (id, type) values (p_event_id, p_type) on conflict (id) do nothing;
  select processed_at into v_done from public.stripe_events where id = p_event_id;
  return v_done is null;
end;
$$;

create or replace function public.webhook_event_done(p_event_id text)
returns void
language sql
security definer
set search_path = public
as $$
  update public.stripe_events set processed_at = now() where id = p_event_id;
$$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
-- Everything here is closed to the API roles unless re-opened below. (Functions are executable by everyone by default.)
revoke execute on function
  public.lock_creator_calendar(uuid),
  public.booking_refund_figures(uuid, boolean),
  public.contract_execute(uuid),
  public.assert_payments_ready(uuid),
  public.payment_prepare(uuid, uuid, text, integer),
  public.payment_attach_intent(uuid, text),
  public.payment_record_success(text, integer, text, text),
  public.payment_record_failure(text, text),
  public.refunds_to_process(uuid),
  public.refund_record_result(uuid, text, text, text),
  public.refund_record_by_stripe_id(text, text, text),
  public.is_booking_party(uuid, uuid),
  public.connect_account_for(uuid),
  public.connect_account_save(uuid, text),
  public.connect_account_update(text, boolean, boolean, boolean),
  public.webhook_claim_event(text, text),
  public.webhook_event_done(text)
from public, anon, authenticated;

revoke execute on function public.cancel_booking(uuid), public.refund_quote(uuid), public.mark_delivered(uuid), public.expire_holds(uuid)
  from public, anon;
grant execute on function public.cancel_booking(uuid), public.refund_quote(uuid), public.mark_delivered(uuid), public.expire_holds(uuid)
  to authenticated;
