-- Messaging before a booking.
--
-- Until now a conversation existed only because a booking did. A client who wants to ask a question first ("Are you free
-- the 14th?", "Do you shoot at night?") had nowhere to ask. An INQUIRY is that conversation: one per client and creator
-- (or company), started from the Message button on the creator's profile.
--
-- Nothing about bookings changes. An inquiry and a booking are two different conversations; each has its own id and its
-- own read marker. The app treats the id as "the conversation" and the backend works out which kind it is, so the
-- functions the app already calls (list_messages, send_message, mark_conversation_read) take either id.
--
-- Who is on the provider side:
--   * a person who sells alone: that person;
--   * a company: the Owner, Admins and Managers answer, Viewers can read. A member whose role only covers the jobs
--     assigned to them (Creator) sees bookings assigned to them but not the company's inquiries, because an inquiry has
--     no one assigned yet.
--
-- Because strangers can now write to each other, there are limits (below), and the app can add reporting and blocking
-- on top of this later without changing the shape.

-- ---------------------------------------------------------------------------
-- A fix this needed: "no one is assigned" must read as "no"
-- ---------------------------------------------------------------------------
-- provider_access answered NULL ("unknown") instead of false for a company's Creator role when nothing is assigned,
-- because "assigned person = this user" is unknown when the assigned person is null. Policies and WHERE clauses treat
-- unknown as no, but a check written as "not provider_access(...)" treats unknown as not-no and lets the person in. An
-- inquiry never has anyone assigned, and an unassigned company booking waiting for a Manager is the same case. Same rule
-- as before, with unknown turned into no.
create or replace function public.provider_access(p_user uuid, p_creator uuid, p_assigned uuid, p_level text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    p_user is not null and (
      p_user = p_creator
      or case p_level
           when 'manage' then public.org_perm_for(p_user, p_creator, 'bookings.manage')
                              or (p_assigned = p_user and public.org_perm_for(p_user, p_creator, 'bookings.manage_assigned'))
           else public.org_perm_for(p_user, p_creator, 'bookings.view_all')
                or (p_assigned = p_user and public.org_perm_for(p_user, p_creator, 'bookings.manage_assigned'))
         end
    ),
    false
  );
$$;

-- ---------------------------------------------------------------------------
-- The numbers the app shares (SlateTests/Fixtures/inquiry_rules.json holds the same ones and both test suites check them)
-- ---------------------------------------------------------------------------
-- How many new conversations one client may start in a day.
create or replace function public.app_inquiries_per_day()
returns integer
language sql
immutable
as $$ select 10 $$;

-- How many messages a client may send in a row without an answer. The creator replying (or booking) lifts it.
create or replace function public.app_inquiry_unanswered_limit()
returns integer
language sql
immutable
as $$ select 5 $$;

-- ---------------------------------------------------------------------------
-- Schema
-- ---------------------------------------------------------------------------
create table public.inquiries (
  id           uuid primary key default gen_random_uuid(),
  client_id    uuid not null references auth.users (id) on delete cascade,
  creator_id   uuid not null references public.creator_profiles (id) on delete cascade,
  -- Names as they were when the conversation started, the way a booking keeps them, so the list can show them without
  -- reading anyone's profile.
  client_name  text not null default '' check (char_length(client_name) <= 80),
  creator_name text not null,
  created_at   timestamptz not null default now(),
  unique (client_id, creator_id)
);
create index inquiries_creator_idx on public.inquiries (creator_id);
alter table public.inquiries enable row level security;

-- Reading only. Inquiries are made by start_inquiry().
create policy "People read their own inquiries"
  on public.inquiries for select
  to authenticated
  using ((select auth.uid()) = client_id or public.provider_view(creator_id, null::uuid));

-- How far each person has read an inquiry. Only the functions below touch it.
create table public.inquiry_reads (
  inquiry_id   uuid not null references public.inquiries (id) on delete cascade,
  user_id      uuid not null references auth.users (id) on delete cascade,
  read_through timestamptz not null,
  primary key (inquiry_id, user_id)
);
alter table public.inquiry_reads enable row level security;
revoke all on public.inquiry_reads from anon, authenticated;

-- A message belongs to a booking or to an inquiry, never both and never neither. Inquiries hold typed text only.
alter table public.messages alter column booking_id drop not null;
alter table public.messages add column inquiry_id uuid references public.inquiries (id) on delete cascade;
alter table public.messages add constraint messages_one_conversation check ((booking_id is null) <> (inquiry_id is null));
alter table public.messages add constraint messages_inquiry_text_only check (inquiry_id is null or kind = 'text');
create index messages_inquiry_idx on public.messages (inquiry_id, created_at, id) where inquiry_id is not null;
create unique index messages_inquiry_client_id_idx on public.messages (inquiry_id, sender_id, client_id)
  where inquiry_id is not null and client_id is not null;

drop policy "People read the conversation on their bookings" on public.messages;
create policy "People read the conversations they are in"
  on public.messages for select
  to authenticated
  using (
    exists (
      select 1 from public.bookings b
       where b.id = booking_id
         and ((select auth.uid()) = b.client_id or public.provider_view(b.creator_id, b.assigned_to))
    )
    -- Inquiries have their own policy, so this finds only the ones the caller is in.
    or exists (select 1 from public.inquiries i where i.id = inquiry_id)
  );

-- ---------------------------------------------------------------------------
-- Starting one
-- ---------------------------------------------------------------------------
-- The conversation between the signed-in person and this creator or company, made if it isn't there yet. Starting it
-- again returns the same one. Nothing shows in anyone's Messages list until a first message is sent.
create or replace function public.start_inquiry(p_creator_id uuid, p_client_name text default '')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_p    public.creator_profiles;
  v_name text := left(btrim(coalesce(p_client_name, '')), 80);
  v_id   uuid;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_p from public.creator_profiles where id = p_creator_id;
  if not found then
    raise exception 'not_found';
  end if;
  -- Nobody messages themselves, and nobody at a company messages their own company.
  if v_uid = p_creator_id or public.org_perm_for(v_uid, p_creator_id, 'team.view') then
    raise exception 'cannot_message_yourself';
  end if;

  select id into v_id from public.inquiries where client_id = v_uid and creator_id = p_creator_id;
  if found then
    if v_name <> '' then
      update public.inquiries set client_name = v_name where id = v_id and client_name is distinct from v_name;
    end if;
    return v_id;
  end if;

  if (select count(*) from public.inquiries
       where client_id = v_uid and created_at > now() - interval '24 hours') >= public.app_inquiries_per_day() then
    raise exception 'too_many_inquiries';
  end if;

  insert into public.inquiries (client_id, creator_id, client_name, creator_name)
  values (v_uid, p_creator_id, v_name, v_p.display_name)
  on conflict (client_id, creator_id) do update
    set client_name = case when excluded.client_name <> '' then excluded.client_name else public.inquiries.client_name end
  returning id into v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------------
-- A new message: who hears about it
-- ---------------------------------------------------------------------------
-- A booking's version is unchanged. An inquiry's goes to the client (when the creator side wrote) or to the people who
-- answer for the creator (when the client wrote). The conversation's id travels as bookingId in the data, which is what
-- the notification opens; there is no booking row to point at.
create or replace function public.messages_notify_text()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b          public.bookings;
  v_i          public.inquiries;
  v_by_creator boolean;
  v_to         uuid;
begin
  if new.inquiry_id is not null then
    select * into v_i from public.inquiries where id = new.inquiry_id;
    if new.sender_id is distinct from v_i.client_id then
      perform public.push_enqueue(v_i.client_id, 'message', null, jsonb_build_object(
        'bookingId', v_i.id, 'role', 'client', 'senderName', v_i.creator_name, 'preview', left(new.body, 300)),
        'message:' || new.id);
    else
      for v_to in select * from public.provider_recipients(v_i.creator_id, null::uuid) loop
        perform public.push_enqueue(v_to, 'message', null, jsonb_build_object(
          'bookingId', v_i.id, 'role', 'creator',
          'senderName', coalesce(nullif(v_i.client_name, ''), 'A client'), 'preview', left(new.body, 300)),
          'message:' || new.id || ':' || v_to);
      end loop;
    end if;
    return null;
  end if;

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

-- ---------------------------------------------------------------------------
-- What the app calls
-- ---------------------------------------------------------------------------
-- How many of the other person's messages this user hasn't read yet, across bookings and inquiries.
create or replace function public.unread_message_count(p_user uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select (
    select count(*)::integer
      from public.messages m
      join public.bookings b on b.id = m.booking_id
      left join public.conversation_reads r on r.booking_id = b.id and r.user_id = p_user
     where (b.client_id = p_user or public.provider_access(p_user, b.creator_id, b.assigned_to, 'view'))
       and b.status <> 'expired'
       and m.kind = 'text'
       and m.sender_id is distinct from p_user
       and m.created_at > coalesce(r.read_through, '-infinity'::timestamptz)
  ) + (
    select count(*)::integer
      from public.messages m
      join public.inquiries i on i.id = m.inquiry_id
      left join public.inquiry_reads r on r.inquiry_id = i.id and r.user_id = p_user
     where (i.client_id = p_user or public.provider_access(p_user, i.creator_id, null::uuid, 'view'))
       and m.kind = 'text'
       and m.sender_id is distinct from p_user
       and m.created_at > coalesce(r.read_through, '-infinity'::timestamptz)
  )
$$;

-- One row per conversation the caller is in, newest first: the bookings (as before) and the inquiries that have at
-- least one message. booking_id is the conversation's id, an inquiry's id when is_inquiry. counterpart_name is the
-- other side, as the caller should see it; creator_id lets the app open that creator's page; i_am_client says which
-- side the caller is on.
drop function public.list_conversations();
create function public.list_conversations()
returns table (
  booking_id        uuid,
  last_message_id   uuid,
  last_kind         text,
  last_event        text,
  last_body         text,
  last_data         jsonb,
  last_sender_id    uuid,
  last_at           timestamptz,
  unread_count      integer,
  is_inquiry        boolean,
  counterpart_name  text,
  creator_id        uuid,
  i_am_client       boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select c.*
    from (
      select b.id as booking_id, m.id as last_message_id, m.kind as last_kind, m.event as last_event, m.body as last_body,
             m.data as last_data, m.sender_id as last_sender_id, m.created_at as last_at,
             (select count(*)::integer from public.messages u
               where u.booking_id = b.id and u.kind = 'text'
                 and u.sender_id is distinct from (select auth.uid())
                 and u.created_at > coalesce(r.read_through, '-infinity'::timestamptz)) as unread_count,
             false as is_inquiry,
             case when b.client_id is not distinct from (select auth.uid()) then b.creator_name else b.client_name end
               as counterpart_name,
             b.creator_id as creator_id,
             b.client_id is not distinct from (select auth.uid()) as i_am_client
        from public.bookings b
        cross join lateral (
          select x.* from public.messages x where x.booking_id = b.id order by x.created_at desc, x.id desc limit 1
        ) m
        left join public.conversation_reads r on r.booking_id = b.id and r.user_id = (select auth.uid())
       where (b.client_id = (select auth.uid()) or public.provider_view(b.creator_id, b.assigned_to))
         and b.status <> 'expired'
         and not (b.status = 'held' and b.hold_expires_at <= now())
      union all
      select i.id, m.id, m.kind, m.event, m.body, m.data, m.sender_id, m.created_at,
             (select count(*)::integer from public.messages u
               where u.inquiry_id = i.id and u.kind = 'text'
                 and u.sender_id is distinct from (select auth.uid())
                 and u.created_at > coalesce(r.read_through, '-infinity'::timestamptz)),
             true,
             case when i.client_id = (select auth.uid()) then i.creator_name else i.client_name end,
             i.creator_id,
             i.client_id = (select auth.uid())
        from public.inquiries i
        cross join lateral (
          select x.* from public.messages x where x.inquiry_id = i.id order by x.created_at desc, x.id desc limit 1
        ) m
        left join public.inquiry_reads r on r.inquiry_id = i.id and r.user_id = (select auth.uid())
       where i.client_id = (select auth.uid()) or public.provider_view(i.creator_id, null::uuid)
    ) c
   order by c.last_at desc, c.last_message_id desc
$$;

revoke execute on function public.list_conversations() from public, anon;
grant execute on function public.list_conversations() to authenticated;

-- The conversation in time order (a booking's or an inquiry's). Row level security decides who can read, so a stranger
-- gets nothing.
create or replace function public.list_messages(p_booking_id uuid, p_since timestamptz default null, p_limit integer default 200)
returns setof public.messages
language sql
stable
as $$
  select * from (
    select m.* from public.messages m
     where (m.booking_id = p_booking_id or m.inquiry_id = p_booking_id) and (p_since is null or m.created_at > p_since)
     order by m.created_at desc, m.id desc
     limit least(greatest(coalesce(p_limit, 200), 1), 500)
  ) newest
  order by created_at, id
$$;

-- Sends a message to a booking's conversation or to an inquiry. Everything about a booking's is as it was; an inquiry
-- is checked the same way (length, rate) plus the unanswered limit for the client.
create or replace function public.send_message(p_booking_id uuid, p_body text, p_client_id uuid default null)
returns public.messages
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid  uuid := auth.uid();
  v_b    public.bookings;
  v_i    public.inquiries;
  v_body text;
  v_row  public.messages;
  v_last timestamptz;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;

  select * into v_b from public.bookings where id = p_booking_id;
  if not found then
    select * into v_i from public.inquiries where id = p_booking_id;
    if not found
       or (v_i.client_id is distinct from v_uid and not public.provider_access(v_uid, v_i.creator_id, null::uuid, 'manage')) then
      raise exception 'not_found';
    end if;
  elsif v_b.client_id is distinct from v_uid and not public.provider_access(v_uid, v_b.creator_id, v_b.assigned_to, 'manage') then
    raise exception 'not_found';
  end if;

  -- Sending the same message again (a dropped connection) returns the one already stored.
  if p_client_id is not null then
    select * into v_row from public.messages
     where (booking_id = p_booking_id or inquiry_id = p_booking_id) and sender_id = v_uid and client_id = p_client_id;
    if found then
      return v_row;
    end if;
  end if;

  if v_b.id is not null then
    -- A hold that ran out never became a booking, and a deleted account has nobody to read the reply.
    if v_b.status = 'expired' or (v_b.status = 'held' and v_b.hold_expires_at <= now())
       or v_b.client_id is null then
      raise exception 'conversation_closed';
    end if;
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

  if v_i.id is not null then
    -- A client who keeps writing with no answer stops at the limit. Any reply from the creator's side lifts it.
    if v_uid = v_i.client_id then
      select max(created_at) into v_last from public.messages
       where inquiry_id = v_i.id and kind = 'text' and sender_id is distinct from v_i.client_id;
      if (select count(*) from public.messages
           where inquiry_id = v_i.id and kind = 'text' and sender_id = v_i.client_id
             and created_at > coalesce(v_last, '-infinity'::timestamptz)) >= public.app_inquiry_unanswered_limit() then
        raise exception 'awaiting_reply';
      end if;
    end if;

    insert into public.messages (inquiry_id, sender_id, kind, body, client_id)
    values (v_i.id, v_uid, 'text', v_body, p_client_id)
    on conflict (inquiry_id, sender_id, client_id) where inquiry_id is not null and client_id is not null do nothing
    returning * into v_row;
    if not found then
      -- The same message arrived twice at the same moment, and the other copy won.
      select * into v_row from public.messages
       where inquiry_id = v_i.id and sender_id = v_uid and client_id = p_client_id;
      return v_row;
    end if;

    insert into public.inquiry_reads (inquiry_id, user_id, read_through)
    values (v_i.id, v_uid, v_row.created_at)
    on conflict (inquiry_id, user_id) do update
      set read_through = greatest(public.inquiry_reads.read_through, excluded.read_through);
    return v_row;
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

  if exists (
    select 1 from public.inquiries i
     where i.id = p_booking_id
       and (i.client_id = v_uid or public.provider_access(v_uid, i.creator_id, null::uuid, 'view'))
  ) then
    select max(created_at) into v_latest from public.messages where inquiry_id = p_booking_id;
    if v_latest is null then
      return;
    end if;
    insert into public.inquiry_reads (inquiry_id, user_id, read_through)
    values (p_booking_id, v_uid, v_latest)
    on conflict (inquiry_id, user_id) do update
      set read_through = greatest(public.inquiry_reads.read_through, excluded.read_through);
    return;
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

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.start_inquiry(uuid, text) from public, anon;
grant execute on function public.start_inquiry(uuid, text) to authenticated;
