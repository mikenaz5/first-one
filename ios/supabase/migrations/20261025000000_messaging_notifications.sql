-- Slate: messaging and notifications
--
-- Every booking has one conversation between its two people. People write text messages; the system adds short
-- event messages ("deposit paid", "cancelled") from what happens to the booking, so the conversation doubles as
-- the booking's history.
--
-- Push notifications are queued here and sent by the `send-push` Edge Function:
--   * Events (new booking, contract signed, payment received, balance due, cancelled, new message) are queued by
--     triggers on the tables they happen in, so no code path can forget to announce itself.
--   * Shoot reminders are queued by enqueue_due_reminders(), which `send-push` calls each time it runs.
--   * The queue holds *facts* (who, what, which booking, the figures), not wording. The Edge Function words them.
--
-- Nothing in this file moves money or changes a booking. It only reads their state and writes messages and queue rows.
--
-- Errors are plain tokens, as elsewhere: not_signed_in, not_found, conversation_closed, invalid_message,
-- message_too_long, rate_limited, invalid_token, invalid_environment.

-- ---------------------------------------------------------------------------
-- Constants and small rules
-- ---------------------------------------------------------------------------
-- When shoot reminders go out, in minutes before the shoot. SlateTests/Fixtures/notification_rules.json holds the
-- same numbers and both test suites check them.
create or replace function public.app_reminder_leads()
returns integer[]
language sql
immutable
as $$ select array[1440, 120] $$;

create or replace function public.app_message_max_length()
returns integer
language sql
immutable
as $$ select 2000 $$;

-- What a message looks like once it is stored: line breaks as LF, control characters removed (tab and LF stay),
-- and no spaces or line breaks around it. Mirrors MessageRules.clean in Swift; the shared fixture checks both.
create or replace function public.message_clean(p_body text)
returns text
language sql
immutable
as $$
  select btrim(
    regexp_replace(
      replace(replace(coalesce(p_body, ''), E'\r\n', E'\n'), E'\r', E'\n'),
      '[\x01-\x08\x0b\x0c\x0e-\x1f\x7f]', '', 'g'),
    E' \n\t')
$$;

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------
create table public.messages (
  id         uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.bookings (id) on delete cascade,
  -- Null for system messages, and kept (as null) if the sender deletes their account.
  sender_id  uuid references auth.users (id) on delete set null,
  kind       text not null check (kind in ('text', 'system')),
  body       text not null default '' check (char_length(body) <= 2000),
  -- System messages only: what happened, and the figures needed to say so. The app words them.
  event      text check (event in ('booked', 'contract_signed', 'deposit_paid', 'delivered', 'balance_paid', 'cancelled')),
  data       jsonb not null default '{}'::jsonb,
  -- Made by the app so that sending again after a dropped connection doesn't post the message twice.
  client_id  uuid,
  -- clock_timestamp, not now(): messages added in one transaction still get distinct, increasing times.
  created_at timestamptz not null default clock_timestamp(),
  constraint messages_shape check (
    (kind = 'text' and event is null and char_length(body) >= 1)
    or (kind = 'system' and event is not null and body = '')
  )
);

create index messages_booking_idx on public.messages (booking_id, created_at, id);
create unique index messages_client_id_idx on public.messages (booking_id, sender_id, client_id) where client_id is not null;

alter table public.messages enable row level security;

-- Reading only. Text messages are written by send_message(), system messages by the triggers below.
create policy "People read the conversation on their bookings"
  on public.messages for select
  to authenticated
  using (exists (
    select 1 from public.bookings b
     where b.id = booking_id
       and ((select auth.uid()) = b.client_id or (select auth.uid()) = b.creator_id)
  ));

-- How far each person has read. Only the functions below touch it.
create table public.conversation_reads (
  booking_id   uuid not null references public.bookings (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  read_through timestamptz not null,
  primary key (booking_id, user_id)
);
alter table public.conversation_reads enable row level security;

-- Anything already booked gets its first line, so existing bookings have a conversation too.
insert into public.messages (booking_id, kind, event, data, created_at)
select b.id, 'system', 'booked',
       jsonb_build_object('packageName', b.package_name, 'startAt', b.start_at, 'timeZone', b.time_zone),
       b.created_at
  from public.bookings b;

-- ---------------------------------------------------------------------------
-- Notification settings, devices and the queue
-- ---------------------------------------------------------------------------
create table public.notification_preferences (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  bookings   boolean not null default true,
  contracts  boolean not null default true,
  payments   boolean not null default true,
  messages   boolean not null default true,
  reminders  boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table public.notification_preferences enable row level security;

-- One row per phone or tablet signed in. APNs tokens are hex; their length isn't promised, so allow a range.
create table public.device_tokens (
  token        text primary key check (token ~ '^[0-9a-f]{32,200}$'),
  user_id      uuid not null references auth.users (id) on delete cascade,
  -- Which APNs server the token belongs to: Xcode builds use sandbox, TestFlight and the App Store use production.
  environment  text not null check (environment in ('sandbox', 'production')),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index device_tokens_user_idx on public.device_tokens (user_id);
alter table public.device_tokens enable row level security;

create table public.push_outbox (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references auth.users (id) on delete cascade,
  kind         text not null check (kind in (
    'new_booking', 'booking_cancelled', 'contract_signed', 'payment_received', 'balance_due', 'message', 'shoot_reminder')),
  booking_id   uuid references public.bookings (id) on delete cascade,
  -- The facts the Edge Function needs to word the notification.
  data         jsonb not null default '{}'::jsonb,
  -- Makes queuing the same thing twice harmless (a reminder run twice, a retried transaction).
  dedupe_key   text unique,
  created_at   timestamptz not null default now(),
  send_after   timestamptz not null default now(),
  attempts     integer not null default 0,
  locked_until timestamptz,
  sent_at      timestamptz,
  last_error   text
);
create index push_outbox_due_idx on public.push_outbox (send_after) where sent_at is null;
alter table public.push_outbox enable row level security;

-- The three tables above have no policies, and the API roles get no direct access either way.
revoke all on public.conversation_reads, public.notification_preferences, public.device_tokens, public.push_outbox
  from anon, authenticated;

-- Which setting a kind of notification belongs to.
create or replace function public.push_category(p_kind text)
returns text
language sql
immutable
as $$
  select case p_kind
    when 'new_booking' then 'bookings'
    when 'booking_cancelled' then 'bookings'
    when 'contract_signed' then 'contracts'
    when 'payment_received' then 'payments'
    when 'balance_due' then 'payments'
    when 'message' then 'messages'
    when 'shoot_reminder' then 'reminders'
  end
$$;

-- Queues one notification, unless the person turned that kind off or it was already queued.
-- Returns whether a row was added.
create or replace function public.push_enqueue(
  p_user uuid, p_kind text, p_booking uuid, p_data jsonb, p_dedupe text default null, p_send_after timestamptz default null
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_prefs jsonb;
  v_rows  integer;
begin
  if p_user is null then
    return false;
  end if;
  select to_jsonb(n) into v_prefs from public.notification_preferences n where n.user_id = p_user;
  if v_prefs is not null and (v_prefs ->> public.push_category(p_kind)) = 'false' then
    return false;
  end if;
  insert into public.push_outbox (user_id, kind, booking_id, data, dedupe_key, send_after)
  values (p_user, p_kind, p_booking, coalesce(p_data, '{}'::jsonb), p_dedupe, coalesce(p_send_after, now()))
  on conflict (dedupe_key) do nothing;
  get diagnostics v_rows = row_count;
  return v_rows > 0;
end;
$$;

-- ---------------------------------------------------------------------------
-- Events: what happens to a booking becomes a message and a notification
-- ---------------------------------------------------------------------------
-- New booking: the first line of the conversation, and a heads-up to the creator.
create or replace function public.bookings_notify_created()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.messages (booking_id, kind, event, data)
  values (new.id, 'system', 'booked',
          jsonb_build_object('packageName', new.package_name, 'startAt', new.start_at, 'timeZone', new.time_zone));
  perform public.push_enqueue(new.creator_id, 'new_booking', new.id, jsonb_build_object(
    'bookingId', new.id, 'role', 'creator', 'clientName', new.client_name, 'packageName', new.package_name,
    'startAt', new.start_at, 'timeZone', new.time_zone, 'pendingDeposit', new.status = 'held',
    'depositCents', new.deposit_cents, 'currency', new.currency_code), 'new_booking:' || new.id);
  return null;
end;
$$;

create trigger bookings_notify_created
  after insert on public.bookings
  for each row execute function public.bookings_notify_created();

-- The creator says the work is delivered: the client now owes the balance, if there is one.
create or replace function public.bookings_notify_delivered()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_balance integer := greatest(new.total_cents - new.deposit_cents, 0);
begin
  insert into public.messages (booking_id, kind, event, data)
  values (new.id, 'system', 'delivered', jsonb_build_object('balanceCents', v_balance, 'currency', new.currency_code));
  if v_balance > 0 then
    perform public.push_enqueue(new.client_id, 'balance_due', new.id, jsonb_build_object(
      'bookingId', new.id, 'role', 'client', 'creatorName', new.creator_name, 'packageName', new.package_name,
      'balanceCents', v_balance, 'currency', new.currency_code), 'balance_due:' || new.id);
  end if;
  return null;
end;
$$;

create trigger bookings_notify_delivered
  after update of delivered_at on public.bookings
  for each row
  when (old.delivered_at is null and new.delivered_at is not null)
  execute function public.bookings_notify_delivered();

-- The next three run when the transaction commits, not as each row changes. cancel_booking() records the refunds
-- *after* it cancels the booking, and a payment that arrives for a booking that can't take it is refunded in the
-- same transaction; waiting until the end means they see the finished picture, and say nothing about a payment
-- that was handed straight back. It also puts the lines of one transaction in the order things happened.
create or replace function public.bookings_notify_cancelled()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_refund     integer;
  v_by_creator boolean := new.cancelled_by is not distinct from new.creator_id;
begin
  select coalesce(sum(p.amount_cents), 0) into v_refund
    from public.payments p
   where p.booking_id = new.id and p.kind = 'refund' and p.status in ('pending', 'succeeded');

  insert into public.messages (booking_id, kind, event, data)
  values (new.id, 'system', 'cancelled', jsonb_build_object(
    'byCreator', v_by_creator, 'refundCents', v_refund, 'currency', new.currency_code));

  -- Tell the other person.
  perform public.push_enqueue(
    case when v_by_creator then new.client_id else new.creator_id end,
    'booking_cancelled', new.id,
    jsonb_build_object(
      'bookingId', new.id, 'role', case when v_by_creator then 'client' else 'creator' end,
      'byName', case when v_by_creator then new.creator_name else new.client_name end,
      'packageName', new.package_name, 'startAt', new.start_at, 'timeZone', new.time_zone,
      'refundCents', v_refund, 'currency', new.currency_code),
    'booking_cancelled:' || new.id);
  return null;
end;
$$;

create constraint trigger bookings_notify_cancelled
  after update of status on public.bookings
  deferrable initially deferred
  for each row
  when (old.status is distinct from new.status and new.status = 'cancelled')
  execute function public.bookings_notify_cancelled();

-- Money arrived: a line in the conversation and a note to both people.
create or replace function public.payments_notify_paid()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b public.bookings;
begin
  select * into v_b from public.bookings where id = new.booking_id;
  -- A payment that couldn't be applied (the booking was cancelled, or its time was taken) has been refunded.
  if not found or v_b.status not in ('confirmed', 'completed') then
    return null;
  end if;

  insert into public.messages (booking_id, kind, event, data)
  values (new.booking_id, 'system', case new.kind when 'deposit' then 'deposit_paid' else 'balance_paid' end,
          jsonb_build_object('amountCents', new.amount_cents, 'currency', new.currency_code));

  perform public.push_enqueue(v_b.creator_id, 'payment_received', v_b.id, jsonb_build_object(
    'bookingId', v_b.id, 'role', 'creator', 'paymentKind', new.kind, 'amountCents', new.amount_cents,
    'currency', new.currency_code, 'clientName', v_b.client_name, 'packageName', v_b.package_name),
    'payment_received:' || new.id || ':creator');
  perform public.push_enqueue(v_b.client_id, 'payment_received', v_b.id, jsonb_build_object(
    'bookingId', v_b.id, 'role', 'client', 'paymentKind', new.kind, 'amountCents', new.amount_cents,
    'currency', new.currency_code, 'creatorName', v_b.creator_name, 'packageName', v_b.package_name),
    'payment_received:' || new.id || ':client');
  return null;
end;
$$;

create constraint trigger payments_notify_paid
  after update of status on public.payments
  deferrable initially deferred
  for each row
  when (old.status is distinct from new.status and new.status = 'succeeded' and new.kind in ('deposit', 'balance'))
  execute function public.payments_notify_paid();

-- Both people have now signed.
create or replace function public.contracts_notify_executed()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b public.bookings;
begin
  select * into v_b from public.bookings where id = new.booking_id;
  if not found or v_b.status not in ('confirmed', 'completed') then
    return null;
  end if;

  insert into public.messages (booking_id, kind, event)
  values (new.booking_id, 'system', 'contract_signed');

  perform public.push_enqueue(v_b.creator_id, 'contract_signed', v_b.id, jsonb_build_object(
    'bookingId', v_b.id, 'role', 'creator', 'packageName', v_b.package_name, 'otherName', v_b.client_name,
    'startAt', v_b.start_at, 'timeZone', v_b.time_zone), 'contract_signed:' || new.id || ':creator');
  perform public.push_enqueue(v_b.client_id, 'contract_signed', v_b.id, jsonb_build_object(
    'bookingId', v_b.id, 'role', 'client', 'packageName', v_b.package_name, 'otherName', v_b.creator_name,
    'startAt', v_b.start_at, 'timeZone', v_b.time_zone), 'contract_signed:' || new.id || ':client');
  return null;
end;
$$;

create constraint trigger contracts_notify_executed
  after update of status on public.contracts
  deferrable initially deferred
  for each row
  when (old.status is distinct from new.status and new.status = 'executed')
  execute function public.contracts_notify_executed();

-- A new message: tell the other person.
create or replace function public.messages_notify_text()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b          public.bookings;
  v_by_creator boolean;
begin
  select * into v_b from public.bookings where id = new.booking_id;
  v_by_creator := new.sender_id = v_b.creator_id;
  perform public.push_enqueue(
    case when v_by_creator then v_b.client_id else v_b.creator_id end,
    'message', v_b.id,
    jsonb_build_object(
      'bookingId', v_b.id, 'role', case when v_by_creator then 'client' else 'creator' end,
      'senderName', case when v_by_creator then v_b.creator_name else v_b.client_name end,
      'preview', left(new.body, 300)),
    'message:' || new.id);
  return null;
end;
$$;

create trigger messages_notify_text
  after insert on public.messages
  for each row
  when (new.kind = 'text')
  execute function public.messages_notify_text();

-- ---------------------------------------------------------------------------
-- Conversations: what the app calls
-- ---------------------------------------------------------------------------
-- How many of the other person's messages this user hasn't read yet. System lines never count.
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
   where (b.client_id = p_user or b.creator_id = p_user)
     and b.status <> 'expired'
     and m.kind = 'text'
     and m.sender_id is distinct from p_user
     and m.created_at > coalesce(r.read_through, '-infinity'::timestamptz)
$$;

-- One row per booking the caller is part of: the latest line and how many messages are unread. Newest first.
-- Bookings whose hold ran out never really happened, so they have no conversation.
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
   where (b.client_id = (select auth.uid()) or b.creator_id = (select auth.uid()))
     and b.status <> 'expired'
     and not (b.status = 'held' and b.hold_expires_at <= now())
   order by m.created_at desc, m.id desc
$$;

-- The conversation in time order. With p_since, only what is newer; always at most the newest p_limit lines.
-- Row level security decides who can read, so a stranger gets nothing.
create or replace function public.list_messages(p_booking_id uuid, p_since timestamptz default null, p_limit integer default 200)
returns setof public.messages
language sql
stable
as $$
  select * from (
    select m.* from public.messages m
     where m.booking_id = p_booking_id and (p_since is null or m.created_at > p_since)
     order by m.created_at desc, m.id desc
     limit least(greatest(coalesce(p_limit, 200), 1), 500)
  ) newest
  order by created_at, id
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
  if not found or (v_b.client_id is distinct from v_uid and v_b.creator_id <> v_uid) then
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
     where b.id = p_booking_id and (b.client_id = v_uid or b.creator_id = v_uid)
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

-- ---------------------------------------------------------------------------
-- Settings and devices: what the app calls
-- ---------------------------------------------------------------------------
create or replace function public.get_notification_preferences()
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select jsonb_build_object(
    'bookings', coalesce(n.bookings, true), 'contracts', coalesce(n.contracts, true),
    'payments', coalesce(n.payments, true), 'messages', coalesce(n.messages, true),
    'reminders', coalesce(n.reminders, true))
    from (select 1) one
    left join public.notification_preferences n on n.user_id = (select auth.uid())
$$;

-- Takes any of the five keys; the ones left out stay as they were. Returns the settings now in force.
create or replace function public.save_notification_preferences(p_prefs jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  insert into public.notification_preferences (user_id, bookings, contracts, payments, messages, reminders)
  values (v_uid,
          coalesce((p_prefs ->> 'bookings')::boolean, true), coalesce((p_prefs ->> 'contracts')::boolean, true),
          coalesce((p_prefs ->> 'payments')::boolean, true), coalesce((p_prefs ->> 'messages')::boolean, true),
          coalesce((p_prefs ->> 'reminders')::boolean, true))
  on conflict (user_id) do update set
    bookings = coalesce((p_prefs ->> 'bookings')::boolean, public.notification_preferences.bookings),
    contracts = coalesce((p_prefs ->> 'contracts')::boolean, public.notification_preferences.contracts),
    payments = coalesce((p_prefs ->> 'payments')::boolean, public.notification_preferences.payments),
    messages = coalesce((p_prefs ->> 'messages')::boolean, public.notification_preferences.messages),
    reminders = coalesce((p_prefs ->> 'reminders')::boolean, public.notification_preferences.reminders),
    updated_at = now();
  return public.get_notification_preferences();
end;
$$;

-- Remembers this device for the signed-in person. A phone someone else used before moves to the new owner.
create or replace function public.register_device(p_token text, p_environment text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_token text := lower(coalesce(p_token, ''));
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  if v_token !~ '^[0-9a-f]{32,200}$' then
    raise exception 'invalid_token';
  end if;
  if p_environment is null or p_environment not in ('sandbox', 'production') then
    raise exception 'invalid_environment';
  end if;

  insert into public.device_tokens (token, user_id, environment)
  values (v_token, v_uid, p_environment)
  on conflict (token) do update
    set user_id = excluded.user_id, environment = excluded.environment, last_seen_at = now();

  -- A person doesn't need more than a handful of devices; forget the least recently seen beyond ten.
  delete from public.device_tokens d
   where d.user_id = v_uid
     and d.token in (
       select t.token from public.device_tokens t where t.user_id = v_uid
        order by t.last_seen_at desc, t.token offset 10);
end;
$$;

create or replace function public.unregister_device(p_token text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.device_tokens where token = lower(coalesce(p_token, '')) and user_id = (select auth.uid());
$$;

-- ---------------------------------------------------------------------------
-- Functions for send-push (service role only)
-- ---------------------------------------------------------------------------
-- Queues the reminders that are due now. A reminder is due from its lead time before the shoot until half that
-- lead is left (a run that was late can still send it, one that was very late can't), only for confirmed bookings
-- that were made before the reminder time (so booking tomorrow's shoot today doesn't also say "tomorrow").
-- Both people are reminded. Safe to run as often as you like.
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
        select u.id, u.role from (values (v_b.creator_id, 'creator'), (v_b.client_id, 'client')) as u (id, role)
      loop
        if v_user is not null and public.push_enqueue(
          v_user, 'shoot_reminder', v_b.id,
          jsonb_build_object(
            'bookingId', v_b.id, 'role', v_role, 'packageName', v_b.package_name,
            'otherName', case when v_role = 'creator' then v_b.client_name else v_b.creator_name end,
            'startAt', v_b.start_at, 'timeZone', v_b.time_zone, 'leadMinutes', v_lead),
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

-- Takes up to p_limit notifications that are due, for two minutes (so two runs don't send the same one), and
-- returns each with the person's devices and their badge count. Reminders for shoots that were cancelled or have
-- started are dropped instead.
create or replace function public.push_claim(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_rows jsonb;
begin
  update public.push_outbox o
     set sent_at = now(), locked_until = null, last_error = 'stale'
   where o.sent_at is null and o.kind = 'shoot_reminder'
     and not exists (
       select 1 from public.bookings b where b.id = o.booking_id and b.status = 'confirmed' and b.start_at > now());

  with due as (
    select id from public.push_outbox
     where sent_at is null and send_after <= now() and attempts < 5
       and (locked_until is null or locked_until < now())
     order by send_after, created_at, id
     limit greatest(1, least(coalesce(p_limit, 50), 200))
     for update skip locked
  ), claimed as (
    update public.push_outbox o
       set attempts = o.attempts + 1, locked_until = now() + interval '2 minutes'
      from due
     where o.id = due.id
    returning o.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', c.id, 'user_id', c.user_id, 'kind', c.kind, 'booking_id', c.booking_id, 'data', c.data,
           'attempts', c.attempts, 'badge', public.unread_message_count(c.user_id),
           'devices', coalesce((
             select jsonb_agg(jsonb_build_object('token', d.token, 'environment', d.environment) order by d.last_seen_at desc, d.token)
               from public.device_tokens d where d.user_id = c.user_id), '[]'::jsonb)
         ) order by c.created_at, c.id), '[]'::jsonb)
    into v_rows
    from claimed c;
  return v_rows;
end;
$$;

-- Records how sending went. Delivered (even to just one device, or to none because the person has none) closes the
-- row. Otherwise it is tried again after a growing pause, up to five times. Tokens APNs said are dead are forgotten.
create or replace function public.push_complete(p_id uuid, p_delivered boolean, p_error text default null, p_dead_tokens text[] default '{}')
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if cardinality(coalesce(p_dead_tokens, '{}'::text[])) > 0 then
    delete from public.device_tokens
     where token = any (p_dead_tokens)
       and user_id = (select user_id from public.push_outbox where id = p_id);
  end if;
  if p_delivered then
    update public.push_outbox
       set sent_at = now(), locked_until = null, last_error = left(p_error, 300)
     where id = p_id;
  else
    update public.push_outbox
       set locked_until = null, last_error = left(p_error, 300),
           send_after = now() + (attempts * attempts) * interval '1 minute'
     where id = p_id;
  end if;
end;
$$;

-- Forgets what was sent a while ago.
create or replace function public.push_prune()
returns integer
language sql
security definer
set search_path = public
as $$
  with gone as (
    delete from public.push_outbox
     where coalesce(sent_at, created_at) < now() - interval '14 days'
    returning 1
  )
  select count(*)::integer from gone
$$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function
  public.push_enqueue(uuid, text, uuid, jsonb, text, timestamptz),
  public.bookings_notify_created(),
  public.bookings_notify_delivered(),
  public.bookings_notify_cancelled(),
  public.payments_notify_paid(),
  public.contracts_notify_executed(),
  public.messages_notify_text(),
  public.unread_message_count(uuid),
  public.enqueue_due_reminders(),
  public.push_claim(integer),
  public.push_complete(uuid, boolean, text, text[]),
  public.push_prune()
from public, anon, authenticated;

revoke execute on function
  public.list_conversations(),
  public.list_messages(uuid, timestamptz, integer),
  public.send_message(uuid, text, uuid),
  public.mark_conversation_read(uuid),
  public.get_notification_preferences(),
  public.save_notification_preferences(jsonb),
  public.register_device(text, text),
  public.unregister_device(text)
from public, anon;
grant execute on function
  public.list_conversations(),
  public.list_messages(uuid, timestamptz, integer),
  public.send_message(uuid, text, uuid),
  public.mark_conversation_read(uuid),
  public.get_notification_preferences(),
  public.save_notification_preferences(jsonb),
  public.register_device(text, text),
  public.unregister_device(text)
to authenticated;
