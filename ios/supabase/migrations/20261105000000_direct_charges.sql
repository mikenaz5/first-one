-- Payments become DIRECT CHARGES on the creator's own Stripe account, and a creator who has no Stripe account (or
-- takes one client's money some other way) can use a fallback: an external payment link, and marking a payment
-- received by hand.
--
-- What changes, and what does not:
--
--   * A booking's deposit or balance is paid by creating the PaymentIntent ON the creator's connected account
--     (a Standard-style account: the creator owns the Stripe relationship and its Dashboard). The money goes straight
--     from the client to the creator; it never touches the Slate Pro platform account. There is no application fee for
--     now (platform_fee_cents stays 0; payment_prepare still understands a fee in basis points for later).
--   * Which account a payment lives on is written on the payment row (stripe_account_id) when it is prepared. The
--     webhook for that account says "payment_intent.succeeded" with its account id, and payment_record_success checks the
--     two agree before it believes anything.
--   * A payment can also be recorded by the creator (or whoever may manage the booking) with payment_mark_received.
--     It has method 'manual', no Stripe ids, and runs through the same state change as a Stripe payment
--     (payment_apply_success), so a booking is confirmed or completed by the same rules whichever way the money came.
--   * A refund of a manual payment is not sent by Stripe: it stays pending until the creator says they sent it
--     (refund_mark_sent).
--   * The creator's payment link is a plain https address plus a few words of instruction ("Zelle to ..."), kept in
--     creator_payment_links. The booking's client reads it through payment_options.
--
-- Nothing here can be reached by the app to say "this was paid" except the provider side of that booking.

-- ---------------------------------------------------------------------------
-- The payments ledger
-- ---------------------------------------------------------------------------
alter table public.payments
  -- The connected account a charge was made on (acct_...). Null for manual payments and for a refund row.
  add column stripe_account_id text,
  -- Who marked a manual payment received (or a manual refund sent).
  add column marked_by uuid references auth.users (id) on delete set null,
  add column note text check (char_length(note) <= 300);

alter table public.payments drop constraint payments_method_check;
alter table public.payments add constraint payments_method_check
  check (method in ('apple_pay', 'card', 'simulated', 'manual'));
-- Money recorded by hand has no Stripe payment behind it.
alter table public.payments add constraint payments_manual_has_no_stripe
  check (method is distinct from 'manual' or (stripe_payment_intent_id is null and stripe_charge_id is null and stripe_refund_id is null));

-- ---------------------------------------------------------------------------
-- The creator's external payment link
-- ---------------------------------------------------------------------------
create table public.creator_payment_links (
  -- The owner: a person, or a company (see connect_account_for).
  creator_id   uuid primary key references public.creator_profiles (id) on delete cascade,
  url          text not null,
  instructions text not null default '' check (char_length(instructions) <= 300),
  updated_at   timestamptz not null default now(),
  constraint creator_payment_links_url_clean check (public.delivery_url_clean(url) = url)
);

alter table public.creator_payment_links enable row level security;

-- Read by the owner (for a company, whoever may manage its Stripe account); written only by payment_link_save.
create policy "Owners read their payment link"
  on public.creator_payment_links for select
  to authenticated
  using (public.acts_for(creator_id, 'payments.connect'));

create or replace function public.payment_link_save(p_owner uuid, p_url text, p_instructions text default '')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url text;
begin
  if not public.acts_for(p_owner, 'payments.connect') then
    raise exception 'not_found';
  end if;
  -- An empty address takes the link away.
  if nullif(btrim(coalesce(p_url, ''), E' \n\t\r'), '') is null then
    delete from public.creator_payment_links where creator_id = p_owner;
    return;
  end if;
  v_url := public.delivery_url_clean(p_url);
  if v_url is null then
    raise exception 'invalid_link';
  end if;
  if not exists (select 1 from public.creator_profiles where id = p_owner) then
    raise exception 'profile_required';
  end if;
  insert into public.creator_payment_links (creator_id, url, instructions)
  values (p_owner, v_url, left(btrim(coalesce(p_instructions, ''), E' \n\t\r'), 300))
  on conflict (creator_id) do update
    set url = excluded.url, instructions = excluded.instructions, updated_at = now();
end;
$$;

-- What a booking's client may do to pay: through Stripe (the creator's account can take cards), through the creator's
-- link, or both. Null when the caller is not that booking's client.
create or replace function public.payment_options(p_booking_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'stripe_ready', coalesce((select a.charges_enabled from public.creator_payment_accounts a where a.creator_id = b.creator_id), false),
    'link_url', l.url,
    'instructions', l.instructions
  )
    from public.bookings b
    left join public.creator_payment_links l on l.creator_id = b.creator_id
   where b.id = p_booking_id and auth.uid() is not null and b.client_id = auth.uid();
$$;

-- A creator is ready to take a deposit when Stripe can take cards OR there is a link to pay through. (This is what
-- stops a client booking a package whose deposit nobody could collect.)
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
  if found and v_pkg.deposit_cents > 0
     and not exists (select 1 from public.creator_payment_accounts a where a.creator_id = v_pkg.creator_id and a.charges_enabled)
     and not exists (select 1 from public.creator_payment_links l where l.creator_id = v_pkg.creator_id)
  then
    raise exception 'payments_not_ready';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- What is owed, and whether it can be paid now
-- ---------------------------------------------------------------------------
-- The one place that says "this deposit/balance is payable". payment_prepare (Apple Pay and saved cards) and
-- payment_mark_received (by hand) both ask it, with the booking row already locked. The tokens are the ones
-- payment_prepare has always raised.
create or replace function public.payment_amount_due(p_b public.bookings, p_kind text, p_allow_expired boolean default false)
returns integer
language plpgsql
stable
set search_path = public
as $$
declare
  v_amount integer;
begin
  if p_kind = 'deposit' then
    if p_b.status = 'expired' and not p_allow_expired then
      raise exception 'hold_expired';
    end if;
    if p_b.status <> 'held' and not (p_allow_expired and p_b.status = 'expired') then
      raise exception 'payment_not_due';
    end if;
    v_amount := p_b.deposit_cents;
  else
    if p_b.status <> 'confirmed' or p_b.receipt_confirmed_at is null then
      raise exception 'balance_not_due';
    end if;
    if p_b.deposit_cents > 0 and not exists (
      select 1 from public.payments where booking_id = p_b.id and kind = 'deposit' and status = 'succeeded'
    ) then
      raise exception 'balance_not_due';
    end if;
    v_amount := p_b.total_cents - p_b.deposit_cents;
  end if;

  if v_amount <= 0 then
    raise exception 'nothing_due';
  end if;
  if exists (select 1 from public.payments where booking_id = p_b.id and kind = p_kind::public.payment_kind and status = 'succeeded') then
    raise exception 'already_paid';
  end if;
  return v_amount;
end;
$$;

-- Opens (or reuses) the payment row for a booking's deposit or balance and says where to charge it: on the creator's own
-- Stripe account ('account'), with no platform fee unless p_fee_bps asks for one.
create or replace function public.payment_prepare(p_user_id uuid, p_booking_id uuid, p_kind text, p_fee_bps integer default 0)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b      public.bookings;
  v_acct   public.creator_payment_accounts;
  v_amount integer;
  v_pay    public.payments;
  v_fee    integer;
  v_reuse  boolean;
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

  v_amount := public.payment_amount_due(v_b, p_kind);

  select * into v_acct from public.creator_payment_accounts where creator_id = v_b.creator_id;
  if not found or not v_acct.charges_enabled then
    raise exception 'payments_not_ready';
  end if;

  v_fee := (v_amount * greatest(coalesce(p_fee_bps, 0), 0)) / 10000;

  select * into v_pay from public.payments
   where booking_id = v_b.id and kind = p_kind::public.payment_kind and status = 'pending' and method is distinct from 'manual';
  v_reuse := found;
  if v_reuse and v_pay.stripe_account_id is distinct from v_acct.stripe_account_id then
    -- The creator has connected a different Stripe account since: an attempt made on the old one can't be paid now.
    update public.payments set status = 'canceled' where id = v_pay.id;
    v_reuse := false;
  end if;
  if not v_reuse then
    insert into public.payments (booking_id, kind, amount_cents, currency_code, platform_fee_cents, status, stripe_account_id)
    values (v_b.id, p_kind::public.payment_kind, v_amount, v_b.currency_code, v_fee, 'pending', v_acct.stripe_account_id)
    returning * into v_pay;
  end if;

  return jsonb_build_object(
    'payment_id', v_pay.id,
    'booking_id', v_b.id,
    'kind', p_kind,
    'amount_cents', v_pay.amount_cents,
    'currency', lower(v_pay.currency_code),
    'fee_cents', v_pay.platform_fee_cents,
    'account', v_pay.stripe_account_id,
    'existing_intent', v_pay.stripe_payment_intent_id,
    'description', initcap(p_kind) || ' for ' || v_b.package_name || ' with ' || v_b.creator_name
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- A payment succeeded: what that does to the booking
-- ---------------------------------------------------------------------------
-- The state change that used to live inside payment_record_success, keyed by the payment row so it serves a Stripe
-- payment and a manual one alike. Safe to call twice. Returns what the caller must do next:
--   confirmed / completed / noop, or refund_required (the money arrived too late or for a cancelled booking).
create or replace function public.payment_apply_success(
  p_payment_id uuid, p_amount_cents integer, p_charge_id text default null, p_method text default 'apple_pay',
  p_marked_by uuid default null, p_note text default null)
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
   where p.id = p_payment_id;
  if not found then
    raise exception 'unknown_payment';
  end if;
  -- The calendar lock first (this may put a booking back on the calendar), then the booking, then its payments:
  -- the same order everywhere, so it can't deadlock with creating or cancelling a booking.
  perform public.lock_creator_calendar(v_creator_id);
  select * into v_b from public.bookings where id = v_booking_id for update;
  select * into v_pay from public.payments where id = p_payment_id for update;

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
         method = coalesce(p_method, method), failure_message = null,
         marked_by = coalesce(p_marked_by, marked_by), note = coalesce(p_note, note)
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

-- Stripe says a payment went through (the webhook for the creator's connected account). p_account_id is the account the
-- event came from: when it is given, it must be the account this payment was made on, or the event is ignored (it
-- can't be about this payment). Safe to call twice.
drop function public.payment_record_success(text, integer, text, text);
create or replace function public.payment_record_success(
  p_intent_id text, p_amount_cents integer, p_charge_id text default null, p_method text default 'apple_pay',
  p_account_id text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_pay public.payments;
begin
  select * into v_pay from public.payments where stripe_payment_intent_id = p_intent_id;
  if not found then
    raise exception 'unknown_payment';
  end if;
  if p_account_id is not null and v_pay.stripe_account_id is distinct from p_account_id then
    return jsonb_build_object('action', 'ignored', 'booking_id', v_pay.booking_id, 'payment_id', v_pay.id);
  end if;
  return public.payment_apply_success(v_pay.id, p_amount_cents, p_charge_id, p_method);
end;
$$;

-- ---------------------------------------------------------------------------
-- Marking a payment received by hand
-- ---------------------------------------------------------------------------
--   not_found       the caller can't manage this booking
--   invalid_kind    not 'deposit' or 'balance'
--   payment_not_due / balance_not_due / nothing_due / already_paid     (as payment_amount_due says)
--   time_taken      a deposit marked after the hold lapsed, and someone has booked the time meanwhile
-- A deposit may be marked after its 15-minute hold ran out (paying outside the app is slower than Apple Pay); it counts only
-- while nobody else has the time.
create or replace function public.payment_mark_received(p_booking_id uuid, p_kind text, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_b      public.bookings;
  v_amount integer;
  v_row    public.payments;
  v_note   text;
  v_res    jsonb;
begin
  if v_uid is null then
    raise exception 'not_found';
  end if;
  if p_kind not in ('deposit', 'balance') then
    raise exception 'invalid_kind';
  end if;
  select * into v_b from public.bookings where id = p_booking_id;
  if not found or not public.provider_access(v_uid, v_b.creator_id, v_b.assigned_to, 'manage') then
    raise exception 'not_found';
  end if;
  v_note := nullif(btrim(left(coalesce(p_note, ''), 300), E' \n\t\r'), '');

  -- Calendar lock first, then the booking row (see lock_creator_calendar).
  perform public.expire_holds(v_b.creator_id);
  select * into v_b from public.bookings where id = p_booking_id for update;
  v_amount := public.payment_amount_due(v_b, p_kind, true);

  -- An Apple Pay attempt still open for this payment is moot. If the client finishes it anyway, Stripe's webhook finds a
  -- payment already made, and the extra money is refunded (payment_apply_success).
  update public.payments set status = 'canceled'
   where booking_id = v_b.id and kind = p_kind::public.payment_kind and status = 'pending';
  insert into public.payments (booking_id, kind, amount_cents, currency_code, status, method, marked_by, note)
  values (v_b.id, p_kind::public.payment_kind, v_amount, v_b.currency_code, 'pending', 'manual', v_uid, v_note)
  returning * into v_row;

  v_res := public.payment_apply_success(v_row.id, v_amount, null, 'manual', v_uid, v_note);
  if v_res ->> 'action' = 'refund_required' then
    -- Rolls the whole call back: nothing was recorded.
    raise exception 'time_taken';
  end if;
  return v_res;
end;
$$;

-- ---------------------------------------------------------------------------
-- Refunds
-- ---------------------------------------------------------------------------
-- What still has to be sent to Stripe for a booking: the refund rows that are pending, of payments Stripe took. A refund
-- of a manual payment is not Stripe's to send (see refund_mark_sent). stripe_account_id says where the refund is made.
drop function public.refunds_to_process(uuid);
create or replace function public.refunds_to_process(p_booking_id uuid)
returns table (refund_id uuid, amount_cents integer, payment_intent_id text, stripe_refund_id text, stripe_account_id text)
language sql
stable
security definer
set search_path = public
as $$
  select r.id, r.amount_cents, p.stripe_payment_intent_id, r.stripe_refund_id, p.stripe_account_id
    from public.payments r
    join public.payments p on p.id = r.refund_of
   where r.booking_id = p_booking_id and r.kind = 'refund' and r.status = 'pending'
     and r.method is distinct from 'manual'
   order by r.created_at;
$$;

-- The creator says they sent a refund that Slate Pro could not send for them (the payment was made by hand).
create or replace function public.refund_mark_sent(p_refund_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_r   public.payments;
  v_b   public.bookings;
begin
  select * into v_r from public.payments where id = p_refund_id and kind = 'refund';
  if not found or v_uid is null then
    raise exception 'not_found';
  end if;
  select * into v_b from public.bookings where id = v_r.booking_id;
  if not public.provider_access(v_uid, v_b.creator_id, v_b.assigned_to, 'manage') then
    raise exception 'not_found';
  end if;
  if v_r.method is distinct from 'manual' then
    raise exception 'invalid_kind';
  end if;
  update public.payments
     set status = 'succeeded', paid_at = coalesce(paid_at, now()), marked_by = v_uid
   where id = p_refund_id and status = 'pending';
end;
$$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function
  public.payment_amount_due(public.bookings, text, boolean),
  public.payment_apply_success(uuid, integer, text, text, uuid, text),
  public.payment_record_success(text, integer, text, text, text),
  public.refunds_to_process(uuid)
from public, anon, authenticated;

revoke execute on function
  public.payment_link_save(uuid, text, text),
  public.payment_options(uuid),
  public.payment_mark_received(uuid, text, text),
  public.refund_mark_sent(uuid)
from public, anon;
grant execute on function
  public.payment_link_save(uuid, text, text),
  public.payment_options(uuid),
  public.payment_mark_received(uuid, text, text),
  public.refund_mark_sent(uuid)
to authenticated;
