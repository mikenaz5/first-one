-- Slate Pro: Slate Files (hosted delivery)
--
-- A creator delivers the finished photos and videos inside the app. The client sees small watermarked previews at once,
-- pays the balance, and then saves the originals. Everything is deleted 30 days after delivery. SPEC.md 5.5 and 8.12.
--
--   files_reserve(booking, …)        creator side. Checks permission, the caps and the allowance, records the file as
--                                    uploading and returns where to put it. Nothing is sent to the database but a name
--                                    and numbers: the bytes go to private storage.
--   files_finalize(file)             creator side. Reads the real sizes from storage and accepts the file, or deletes and
--                                    refuses one that is bigger than was reserved.
--   files_deliver(booking, …)        creator side. Makes the draft a delivery (or a revision): starts the 30 days and,
--                                    for the first delivery, makes the balance payable and completes a booking that
--                                    owes nothing.
--   files_remove(file)               creator side. Frees the space and queues the bytes for deletion.
--   files_mark_saved(file)           the client, once an original is theirs to open.
--   files_report(file, reason)       either person.
--   list_booking_files(booking)      what the person looking is allowed to see, for the screen.
--   files_storage_usage(owner)       "4.2 of 25 GB used".
--   files_expire_due() and the purge functions    for the scheduled job (the expire-files Edge Function).
--
-- Who can open which bytes is decided by the policies on storage.objects, at the moment of asking: a signed link is made
-- under the caller's own access, so a link can't be made for an original that is still locked. Whether anything is owed
-- comes from payments recorded by Stripe's signed webhook, like everything else about money.
--
-- Deleting rows does not free bytes: every path that stops being needed is put in storage_purge, and the scheduled job
-- deletes those objects through the Storage API.
--
-- Errors are plain tokens, as elsewhere: not_signed_in, not_found, files_not_allowed, unsupported_type, delivery_locked,
-- revision_not_allowed, too_many_files, file_empty, file_too_large, preview_too_large, storage_full, upload_incomplete,
-- nothing_to_deliver, files_not_ready, note_too_long, title_too_long, originals_locked.

-- ---------------------------------------------------------------------------
-- Settings (SPEC 4.4): the numbers that can change without touching rules code
-- ---------------------------------------------------------------------------
insert into public.app_settings (key, value) values
  ('files', '{
    "retention_days": 30, "draft_days": 7, "warn_days": [7, 1],
    "quota_gb_individual": 25, "quota_gb_per_seat": 25,
    "max_photo_mb": 100, "max_video_gb": 4, "max_files": 1000,
    "preview_photo_max_mb": 5, "preview_video_max_mb": 150,
    "url_minutes": 15, "reservation_hours": 24
  }');

alter table public.app_settings add constraint files_settings_make_sense check (
  key <> 'files' or (
    (value ->> 'retention_days')::integer between 1 and 365
    and (value ->> 'draft_days')::integer between 1 and 90
    and jsonb_typeof(value -> 'warn_days') = 'array'
    and (value ->> 'quota_gb_individual')::integer between 1 and 100000
    and (value ->> 'quota_gb_per_seat')::integer between 1 and 100000
    and (value ->> 'max_photo_mb')::integer between 1 and 10000
    and (value ->> 'max_video_gb')::integer between 1 and 100
    and (value ->> 'max_files')::integer between 1 and 100000
    and (value ->> 'preview_photo_max_mb')::integer between 1 and 1000
    and (value ->> 'preview_video_max_mb')::integer between 1 and 10000
    and (value ->> 'url_minutes')::integer between 1 and 1440
    and (value ->> 'reservation_hours')::integer between 1 and 168
  )
);

create or replace function public.files_setting_int(p_field text, p_default integer)
returns integer
language sql
stable
security definer
set search_path = public
as $$ select public.app_setting_int('files', p_field, p_default) $$;

create or replace function public.files_warn_days()
returns integer[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select array(select jsonb_array_elements_text(value -> 'warn_days')::integer) from public.app_settings where key = 'files'),
    array[7, 1]);
$$;

-- What the app shows and checks against, so the numbers aren't hard-coded there.
create or replace function public.files_config()
returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'retention_days', public.files_setting_int('retention_days', 30),
    'draft_days', public.files_setting_int('draft_days', 7),
    'warn_days', to_jsonb(public.files_warn_days()),
    'quota_gb_individual', public.files_setting_int('quota_gb_individual', 25),
    'quota_gb_per_seat', public.files_setting_int('quota_gb_per_seat', 25),
    'max_photo_mb', public.files_setting_int('max_photo_mb', 100),
    'max_video_gb', public.files_setting_int('max_video_gb', 4),
    'max_files', public.files_setting_int('max_files', 1000),
    'preview_photo_max_mb', public.files_setting_int('preview_photo_max_mb', 5),
    'preview_video_max_mb', public.files_setting_int('preview_video_max_mb', 150),
    'url_minutes', public.files_setting_int('url_minutes', 15),
    'reservation_hours', public.files_setting_int('reservation_hours', 24)
  );
$$;

-- ---------------------------------------------------------------------------
-- The rules, as pure functions. Mirror FileRules in Swift; file_rules.json checks both.
-- ---------------------------------------------------------------------------
-- A file may be added, in this order: room in the delivery, not empty, original within its cap, preview within its cap,
-- room in the allowance. Null when it may. Sizes are decimal (a 100 MB photo is 100,000,000 bytes).
create or replace function public.files_check_caps(
  p_kind text, p_original bigint, p_preview bigint, p_files integer, p_used bigint, p_allowance bigint
)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_files >= public.files_setting_int('max_files', 1000) then 'too_many_files'
    when coalesce(p_original, 0) <= 0 or coalesce(p_preview, 0) <= 0 then 'file_empty'
    when p_original > case p_kind
           when 'photo' then public.files_setting_int('max_photo_mb', 100)::bigint * 1000000
           else public.files_setting_int('max_video_gb', 4)::bigint * 1000000000 end then 'file_too_large'
    when p_preview > case p_kind
           when 'photo' then public.files_setting_int('preview_photo_max_mb', 5)::bigint * 1000000
           else public.files_setting_int('preview_video_max_mb', 150)::bigint * 1000000 end then 'preview_too_large'
    when p_used + p_original + p_preview > p_allowance then 'storage_full'
  end;
$$;

-- An individual's allowance, or a company's: per billed seat, shared by everyone in it.
create or replace function public.files_allowance_bytes(p_individual boolean, p_billed_seats integer)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select case
    when p_individual then public.files_setting_int('quota_gb_individual', 25)::bigint * 1000000000
    else public.files_setting_int('quota_gb_per_seat', 25)::bigint * greatest(coalesce(p_billed_seats, 0), 0) * 1000000000
  end;
$$;

create or replace function public.files_expires_at(p_delivered timestamptz)
returns timestamptz
language sql
stable
security definer
set search_path = public
as $$ select p_delivered + make_interval(secs => public.files_setting_int('retention_days', 30) * 86400) $$;

-- Whether a person can open a preview or an original. The client sees a delivery's previews from delivery until it
-- ends, and its originals only when nothing is owed (a revision is never locked). The creator side sees everything while
-- it exists. p_viewer is 'client', 'provider' or anything else (which sees nothing).
create or replace function public.files_can_open(
  p_part text, p_viewer text, p_delivery_kind text, p_state text, p_expires timestamptz, p_owed integer,
  p_now timestamptz default now()
)
returns boolean
language sql
immutable
as $$
  select case p_viewer
    when 'provider' then case p_state
                           when 'draft' then true
                           when 'delivered' then coalesce(p_expires > p_now, false)
                           else false end
    when 'client' then p_state = 'delivered'
                       and coalesce(p_expires > p_now, false)
                       and (p_part = 'preview' or p_delivery_kind = 'revision' or p_owed <= 0)
    else false
  end;
$$;

-- Which reminder applies right now: the smallest number of days (of warn_days) that the end is within, while the
-- files are still there.
create or replace function public.files_reminder_day(p_expires timestamptz, p_now timestamptz default now())
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select (select min(d) from unnest(public.files_warn_days()) as d where p_now >= p_expires - make_interval(secs => d * 86400.0))
   where p_expires > p_now;
$$;

-- The first delivery is by files or by link, and the choice is locked once a link has been shared (so the client isn't
-- left with two) or the client has paid the balance.
create or replace function public.files_first_delivery_locked(p_has_files boolean, p_link_delivered boolean, p_paid boolean)
returns boolean
language sql
immutable
as $$ select not p_has_files and (p_link_delivered or p_paid) $$;

-- A revision needs a first delivery that was made, and nothing owed: it is not a way round payment (R21).
create or replace function public.files_revision_allowed(p_first_state text, p_owed integer)
returns boolean
language sql
immutable
as $$ select coalesce(p_first_state in ('delivered', 'expired'), false) and p_owed <= 0 $$;

create or replace function public.files_revision_title(p_sequence integer)
returns text
language sql
immutable
as $$ select 'Revision ' || p_sequence $$;

-- A file's name as it is kept and shown: no slashes or control characters (they become a space), runs of spaces
-- collapsed, at most 120 characters, and "Untitled" if nothing is left.
create or replace function public.files_clean_name(p_name text)
returns text
language sql
immutable
as $$
  select coalesce(nullif(btrim(left(btrim(
    regexp_replace(regexp_replace(coalesce(p_name, ''), E'[\\x01-\\x1f\\x7f/\\\\]+', ' ', 'g'), ' +', ' ', 'g'),
    ' '), 120), ' '), ''), 'Untitled');
$$;

-- Which kind of file a content type is, or null if Slate Pro doesn't take it.
create or replace function public.files_kind_for(p_content_type text)
returns text
language sql
immutable
as $$
  select case lower(coalesce(p_content_type, ''))
    when 'image/jpeg' then 'photo' when 'image/png' then 'photo' when 'image/heic' then 'photo'
    when 'image/heif' then 'photo' when 'image/tiff' then 'photo' when 'image/webp' then 'photo'
    when 'video/mp4' then 'video' when 'video/quicktime' then 'video' when 'video/x-m4v' then 'video'
  end;
$$;

-- ---------------------------------------------------------------------------
-- Tables. Closed to the API: everything goes through the functions below.
-- ---------------------------------------------------------------------------
create table public.deliveries (
  id           uuid primary key default gen_random_uuid(),
  booking_id   uuid not null references public.bookings (id) on delete cascade,
  -- Whose allowance the files count against: the owner of the booking (a person, or a company).
  owner_id     uuid not null references public.creator_profiles (id) on delete cascade,
  kind         text not null check (kind in ('delivery', 'revision')),
  -- 0 for the delivery; 1, 2 and so on for revisions.
  sequence     integer not null check (sequence >= 0),
  title        text not null default '' check (char_length(title) <= 80),
  note         text not null default '' check (char_length(note) <= 500),
  state        text not null default 'draft' check (state in ('draft', 'delivered', 'expired')),
  created_by   uuid references auth.users (id) on delete set null,
  created_at   timestamptz not null default now(),
  delivered_at timestamptz,
  expires_at   timestamptz,
  expired_at   timestamptz,
  unique (booking_id, sequence),
  constraint deliveries_kind_matches_sequence check ((kind = 'delivery') = (sequence = 0)),
  constraint deliveries_dates_match_state check (
    ((state = 'draft') = (delivered_at is null and expires_at is null))
    and ((state = 'expired') = (expired_at is not null))
  )
);
-- One delivery is put together at a time.
create unique index deliveries_one_draft on public.deliveries (booking_id) where state = 'draft';
create index deliveries_due_idx on public.deliveries (expires_at) where state = 'delivered';

create table public.delivery_files (
  id               uuid primary key default gen_random_uuid(),
  delivery_id      uuid not null references public.deliveries (id) on delete cascade,
  booking_id       uuid not null references public.bookings (id) on delete cascade,
  owner_id         uuid not null references public.creator_profiles (id) on delete cascade,
  kind             text not null check (kind in ('photo', 'video')),
  name             text not null check (char_length(name) between 1 and 120),
  content_type     text not null,
  width            integer check (width is null or width > 0),
  height           integer check (height is null or height > 0),
  duration_seconds numeric check (duration_seconds is null or duration_seconds >= 0),
  -- Lowercase UUIDs: <owner>/<booking>/<file>/original and …/preview, in the private bucket "deliveries".
  original_path    text not null unique,
  preview_path     text not null unique,
  -- What was reserved, then what storage really holds once the file is finished.
  original_bytes   bigint not null check (original_bytes > 0),
  preview_bytes    bigint not null check (preview_bytes > 0),
  -- uploading: space is reserved and the bytes are on their way.
  status           text not null default 'uploading' check (status in ('uploading', 'ready', 'removed', 'expired')),
  position         integer not null default 0,
  created_by       uuid references auth.users (id) on delete set null,
  created_at       timestamptz not null default now(),
  ready_at         timestamptz,
  -- When the client first saved the original.
  saved_at         timestamptz,
  removed_at       timestamptz,
  removed_by       uuid references auth.users (id) on delete set null
);
create index delivery_files_delivery_idx on public.delivery_files (delivery_id, position, created_at);
create index delivery_files_live_idx on public.delivery_files (owner_id) where status in ('uploading', 'ready');
create index delivery_files_booking_idx on public.delivery_files (booking_id);

-- Reports go to the support console (R16); nothing here acts on them.
create table public.file_reports (
  id          uuid primary key default gen_random_uuid(),
  file_id     uuid not null references public.delivery_files (id) on delete cascade,
  booking_id  uuid not null references public.bookings (id) on delete cascade,
  reporter_id uuid references auth.users (id) on delete set null,
  reason      text not null check (char_length(reason) between 1 and 500),
  created_at  timestamptz not null default now()
);

-- Objects waiting to be deleted from storage by the scheduled job.
create table public.storage_purge (
  path      text primary key,
  queued_at timestamptz not null default now()
);

alter table public.deliveries enable row level security;
alter table public.delivery_files enable row level security;
alter table public.file_reports enable row level security;
alter table public.storage_purge enable row level security;
revoke all on public.deliveries, public.delivery_files, public.file_reports, public.storage_purge from anon, authenticated;

-- Whatever deletes a file row (removing it, deleting a booking, a profile or an account) leaves its bytes to be purged.
create or replace function public.delivery_files_queue_purge()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.storage_purge (path) values (old.original_path), (old.preview_path) on conflict do nothing;
  return old;
end;
$$;

create trigger delivery_files_queue_purge
  before delete on public.delivery_files
  for each row execute function public.delivery_files_queue_purge();

-- ---------------------------------------------------------------------------
-- What is owed, and how much room is left
-- ---------------------------------------------------------------------------
-- What the client still owes on a booking: the total less what Stripe has said was paid.
create or replace function public.booking_owed_cents(p_booking_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select greatest(0, b.total_cents - coalesce((
    select sum(p.amount_cents) from public.payments p
     where p.booking_id = b.id and p.kind in ('deposit', 'balance') and p.status = 'succeeded'), 0))::integer
    from public.bookings b where b.id = p_booking_id;
$$;

-- Bytes reserved, uploading or ready for an owner: originals and previews, not what was removed or has expired.
create or replace function public.files_owner_used_bytes(p_owner uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(original_bytes + preview_bytes), 0)::bigint
    from public.delivery_files where owner_id = p_owner and status in ('uploading', 'ready');
$$;

create or replace function public.files_owner_allowance_bytes(p_owner uuid)
returns bigint
language sql
stable
security definer
set search_path = public
as $$
  select public.files_allowance_bytes(p.kind = 'person', case when p.kind = 'company' then public.org_seats_wanted(p.id) else 0 end)
    from public.creator_profiles p where p.id = p_owner;
$$;

create or replace function public.files_balance_paid(p_booking_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (select 1 from public.payments where booking_id = p_booking_id and kind = 'balance' and status = 'succeeded');
$$;

-- ---------------------------------------------------------------------------
-- Private storage, and who may put in and take out
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'deliveries', 'deliveries', false, 4000000000,
  array['image/jpeg', 'image/png', 'image/heic', 'image/heif', 'image/tiff', 'image/webp', 'video/mp4', 'video/quicktime', 'video/x-m4v']
)
on conflict (id) do nothing;

-- The creator side may store the two objects of a file that is still uploading, and nothing else.
create or replace function public.files_may_store(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.delivery_files f
      join public.bookings b on b.id = f.booking_id
     where f.status = 'uploading'
       and p_name in (f.original_path, f.preview_path)
       and public.provider_access(auth.uid(), b.creator_id, b.assigned_to, 'manage')
  );
$$;

-- Who can read an object, decided at the moment of asking (so also when a signed link is made).
create or replace function public.files_may_read(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
      from public.delivery_files f
      join public.deliveries d on d.id = f.delivery_id
      join public.bookings b on b.id = f.booking_id
     where p_name in (f.original_path, f.preview_path)
       and f.status in ('uploading', 'ready')
       and (
         (public.provider_access(auth.uid(), b.creator_id, b.assigned_to, 'manage')
            and public.files_can_open('original', 'provider', d.kind, d.state, d.expires_at, 0))
         or (f.status = 'ready' and b.client_id = auth.uid()
            and public.files_can_open(case when p_name = f.preview_path then 'preview' else 'original' end,
                                      'client', d.kind, d.state, d.expires_at, public.booking_owed_cents(b.id)))
       )
  );
$$;

create policy "The creator side stores the files it reserved"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'deliveries' and public.files_may_store(name));

create policy "The creator side replaces the files it reserved"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'deliveries' and public.files_may_store(name))
  with check (bucket_id = 'deliveries' and public.files_may_store(name));

create policy "People read the files they may open"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'deliveries' and public.files_may_read(name));

-- (No delete policy: bytes are removed only by the scheduled job, with the service role.)

-- ---------------------------------------------------------------------------
-- Conversation lines and notifications
-- ---------------------------------------------------------------------------
alter table public.messages drop constraint messages_event_check;
alter table public.messages add constraint messages_event_check check (event in (
  'booked', 'contract_signed', 'deposit_paid', 'delivery_shared', 'receipt_confirmed', 'balance_paid', 'reviewed', 'cancelled',
  'files_delivered', 'files_expired'));

alter table public.push_outbox drop constraint push_outbox_kind_check;
alter table public.push_outbox add constraint push_outbox_kind_check check (kind in (
  'new_booking', 'booking_cancelled', 'contract_signed', 'payment_received', 'balance_due', 'message', 'shoot_reminder',
  'delivery_shared', 'receipt_confirmed', 'review_received', 'files_delivered', 'files_expiring', 'files_expired'));

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
    when 'files_delivered' then 'bookings'
    when 'files_expiring' then 'bookings'
    when 'files_expired' then 'bookings'
    when 'contract_signed' then 'contracts'
    when 'payment_received' then 'payments'
    when 'balance_due' then 'payments'
    when 'message' then 'messages'
    when 'shoot_reminder' then 'reminders'
  end
$$;

-- A hosted delivery has no confirm step (the previews are how the client checks the work), so the booking is marked
-- received when the files are delivered. That must not announce "the client confirmed" to the creator.
drop trigger bookings_notify_receipt on public.bookings;
create trigger bookings_notify_receipt
  after update of receipt_confirmed_at on public.bookings
  for each row
  when (old.receipt_confirmed_at is null and new.receipt_confirmed_at is not null and new.delivery_url is not null)
  execute function public.bookings_notify_receipt();

-- The files were delivered: a line in the conversation and a note to the client.
create or replace function public.deliveries_notify_delivered()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b      public.bookings;
  v_photos integer;
  v_videos integer;
begin
  select * into v_b from public.bookings where id = new.booking_id;
  select count(*) filter (where kind = 'photo'), count(*) filter (where kind = 'video')
    into v_photos, v_videos
    from public.delivery_files where delivery_id = new.id and status = 'ready';
  insert into public.messages (booking_id, kind, event, data)
  values (new.booking_id, 'system', 'files_delivered',
          jsonb_build_object('revised', new.kind = 'revision', 'title', new.title, 'photos', v_photos, 'videos', v_videos));
  perform public.push_enqueue(v_b.client_id, 'files_delivered', v_b.id, jsonb_build_object(
    'bookingId', v_b.id, 'role', 'client', 'creatorName', v_b.creator_name, 'packageName', v_b.package_name,
    'revised', new.kind = 'revision', 'title', new.title, 'photos', v_photos, 'videos', v_videos,
    'balanceCents', public.booking_owed_cents(v_b.id), 'currency', v_b.currency_code),
    'files_delivered:' || new.id);
  return null;
end;
$$;

create trigger deliveries_notify_delivered
  after update of state on public.deliveries
  for each row
  when (old.state = 'draft' and new.state = 'delivered')
  execute function public.deliveries_notify_delivered();

-- The time is up: a line in the conversation and a note to the creator side, with how many files the client saved.
create or replace function public.deliveries_notify_expired()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_b     public.bookings;
  v_total integer;
  v_saved integer;
  v_to    uuid;
begin
  select * into v_b from public.bookings where id = new.booking_id;
  select count(*), count(*) filter (where saved_at is not null)
    into v_total, v_saved
    from public.delivery_files where delivery_id = new.id and status in ('ready', 'expired');
  insert into public.messages (booking_id, kind, event, data)
  values (new.booking_id, 'system', 'files_expired',
          jsonb_build_object('revised', new.kind = 'revision', 'title', new.title, 'saved', v_saved, 'total', v_total));
  for v_to in select * from public.provider_recipients(v_b.creator_id, v_b.assigned_to) loop
    perform public.push_enqueue(v_to, 'files_expired', v_b.id, jsonb_build_object(
      'bookingId', v_b.id, 'role', 'creator', 'clientName', v_b.client_name, 'packageName', v_b.package_name,
      'revised', new.kind = 'revision', 'title', new.title, 'saved', v_saved, 'total', v_total),
      'files_expired:' || new.id || ':' || v_to);
  end loop;
  return null;
end;
$$;

create trigger deliveries_notify_expired
  after update of state on public.deliveries
  for each row
  when (old.state = 'delivered' and new.state = 'expired')
  execute function public.deliveries_notify_expired();

-- ---------------------------------------------------------------------------
-- The creator side: reserve, finish, deliver, remove
-- ---------------------------------------------------------------------------
-- Records a file as uploading and says where its two objects go. Refuses what doesn't fit, before any bytes are sent.
create or replace function public.files_reserve(
  p_booking_id     uuid,
  p_kind           text,
  p_name           text,
  p_content_type   text,
  p_width          integer,
  p_height         integer,
  p_duration       numeric,
  p_original_bytes bigint,
  p_preview_bytes  bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_b        public.bookings;
  v_first    public.deliveries;
  v_delivery public.deliveries;
  v_kind     text;
  v_owed     integer;
  v_files    integer;
  v_used     bigint;
  v_allow    bigint;
  v_refusal  text;
  v_file     uuid := gen_random_uuid();
  v_orig     text;
  v_prev     text;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_b from public.bookings where id = p_booking_id;
  if not found or not public.provider_access(v_uid, v_b.creator_id, v_b.assigned_to, 'manage') then
    raise exception 'not_found';
  end if;
  -- One reservation at a time for an owner, so two phones can't both squeeze into the last of the allowance.
  perform pg_advisory_xact_lock(hashtextextended('slate:files:' || v_b.creator_id::text, 0));
  select * into v_b from public.bookings where id = p_booking_id for update;
  if v_b.status not in ('confirmed', 'completed') or v_b.start_at > now() then
    raise exception 'files_not_allowed';
  end if;
  if p_kind not in ('photo', 'video') or public.files_kind_for(p_content_type) is distinct from p_kind then
    raise exception 'unsupported_type';
  end if;

  v_owed := public.booking_owed_cents(v_b.id);
  select * into v_first from public.deliveries where booking_id = v_b.id and sequence = 0;
  if v_first.id is null or v_first.state = 'draft' then
    v_kind := 'delivery';
    if public.files_first_delivery_locked(false, v_b.delivery_url is not null or v_b.receipt_confirmed_at is not null, public.files_balance_paid(v_b.id)) then
      raise exception 'delivery_locked';
    end if;
  else
    v_kind := 'revision';
    if not public.files_revision_allowed(v_first.state, v_owed) then
      raise exception 'revision_not_allowed';
    end if;
  end if;

  select * into v_delivery from public.deliveries where booking_id = v_b.id and state = 'draft';
  if not found then
    insert into public.deliveries (booking_id, owner_id, kind, sequence, created_by)
    values (v_b.id, v_b.creator_id, v_kind,
            case when v_kind = 'delivery' then 0 else coalesce((select max(sequence) from public.deliveries where booking_id = v_b.id), 0) + 1 end,
            v_uid)
    returning * into v_delivery;
  end if;

  select count(*) into v_files from public.delivery_files where delivery_id = v_delivery.id and status in ('uploading', 'ready');
  v_used := public.files_owner_used_bytes(v_b.creator_id);
  v_allow := public.files_owner_allowance_bytes(v_b.creator_id);
  v_refusal := public.files_check_caps(p_kind, p_original_bytes, p_preview_bytes, v_files, v_used, v_allow);
  if v_refusal is not null then
    raise exception '%', v_refusal;
  end if;

  v_orig := v_b.creator_id::text || '/' || v_b.id::text || '/' || v_file::text || '/original';
  v_prev := v_b.creator_id::text || '/' || v_b.id::text || '/' || v_file::text || '/preview';
  insert into public.delivery_files (
    id, delivery_id, booking_id, owner_id, kind, name, content_type, width, height, duration_seconds,
    original_path, preview_path, original_bytes, preview_bytes, status, position, created_by
  ) values (
    v_file, v_delivery.id, v_b.id, v_b.creator_id, p_kind, public.files_clean_name(p_name), lower(p_content_type), p_width, p_height, p_duration,
    v_orig, v_prev, p_original_bytes, p_preview_bytes, 'uploading',
    coalesce((select max(position) + 1 from public.delivery_files where delivery_id = v_delivery.id), 0), v_uid
  );

  return jsonb_build_object(
    'file_id', v_file, 'delivery_id', v_delivery.id, 'delivery_kind', v_delivery.kind,
    'original_path', v_orig, 'preview_path', v_prev,
    'used_bytes', v_used + p_original_bytes + p_preview_bytes, 'allowance_bytes', v_allow);
end;
$$;

-- The bytes are in storage: read their real sizes and accept the file, or delete and refuse one bigger than was reserved.
-- Returns { accepted, refusal, file_id }. (A refusal is an answer, not an error, so that the removal it makes sticks.)
create or replace function public.files_finalize(p_file_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid     uuid := auth.uid();
  v_f       public.delivery_files;
  v_b       public.bookings;
  v_orig    bigint;
  v_prev    bigint;
  v_refusal text;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_f from public.delivery_files where id = p_file_id for update;
  if not found then
    raise exception 'not_found';
  end if;
  select * into v_b from public.bookings where id = v_f.booking_id;
  if not public.provider_access(v_uid, v_b.creator_id, v_b.assigned_to, 'manage') then
    raise exception 'not_found';
  end if;
  if v_f.status = 'ready' then
    return jsonb_build_object('accepted', true, 'refusal', null, 'file_id', v_f.id);
  end if;
  if v_f.status <> 'uploading' then
    raise exception 'not_found';
  end if;

  select (metadata ->> 'size')::bigint into v_orig from storage.objects where bucket_id = 'deliveries' and name = v_f.original_path;
  select (metadata ->> 'size')::bigint into v_prev from storage.objects where bucket_id = 'deliveries' and name = v_f.preview_path;
  if coalesce(v_orig, 0) <= 0 or coalesce(v_prev, 0) <= 0 then
    raise exception 'upload_incomplete';
  end if;

  v_refusal := case
    when v_orig > v_f.original_bytes then 'file_too_large'
    when v_prev > v_f.preview_bytes
      or v_prev > case v_f.kind
                    when 'photo' then public.files_setting_int('preview_photo_max_mb', 5)::bigint * 1000000
                    else public.files_setting_int('preview_video_max_mb', 150)::bigint * 1000000 end then 'preview_too_large'
  end;
  if v_refusal is not null then
    update public.delivery_files set status = 'removed', removed_at = now(), removed_by = v_uid where id = v_f.id;
    insert into public.storage_purge (path) values (v_f.original_path), (v_f.preview_path) on conflict do nothing;
    return jsonb_build_object('accepted', false, 'refusal', v_refusal, 'file_id', v_f.id);
  end if;

  update public.delivery_files
     set original_bytes = v_orig, preview_bytes = v_prev, status = 'ready', ready_at = now()
   where id = v_f.id;
  return jsonb_build_object('accepted', true, 'refusal', null, 'file_id', v_f.id);
end;
$$;

-- Makes the draft a delivery (or a revision). Starts the 30 days. For the first delivery, marks the booking received (a
-- hosted delivery has no confirm step), which makes the balance payable, and completes a booking that owes nothing.
create or replace function public.files_deliver(p_booking_id uuid, p_title text default null, p_note text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid       uuid := auth.uid();
  v_b         public.bookings;
  v_d         public.deliveries;
  v_first     public.deliveries;
  v_ready     integer;
  v_uploading integer;
  v_note      text;
  v_title     text;
  v_clean     text;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_b from public.bookings where id = p_booking_id for update;
  if not found or not public.provider_access(v_uid, v_b.creator_id, v_b.assigned_to, 'manage') then
    raise exception 'not_found';
  end if;
  if v_b.status not in ('confirmed', 'completed') then
    raise exception 'files_not_allowed';
  end if;
  select * into v_d from public.deliveries where booking_id = v_b.id and state = 'draft' for update;
  if not found then
    raise exception 'nothing_to_deliver';
  end if;
  select count(*) filter (where status = 'ready'), count(*) filter (where status = 'uploading')
    into v_ready, v_uploading
    from public.delivery_files where delivery_id = v_d.id;
  if v_uploading > 0 then
    raise exception 'files_not_ready';
  end if;
  if v_ready = 0 then
    raise exception 'nothing_to_deliver';
  end if;

  v_note := nullif(public.message_clean(p_note), '');
  if char_length(coalesce(v_note, '')) > public.delivery_note_max_length() then
    raise exception 'note_too_long';
  end if;

  if v_d.kind = 'delivery' then
    if public.files_first_delivery_locked(false, v_b.delivery_url is not null or v_b.receipt_confirmed_at is not null, public.files_balance_paid(v_b.id)) then
      raise exception 'delivery_locked';
    end if;
    v_title := '';
  else
    select * into v_first from public.deliveries where booking_id = v_b.id and sequence = 0;
    if not public.files_revision_allowed(v_first.state, public.booking_owed_cents(v_b.id)) then
      raise exception 'revision_not_allowed';
    end if;
    v_clean := coalesce(public.message_clean(p_title), '');
    if char_length(v_clean) > 80 then
      raise exception 'title_too_long';
    end if;
    v_title := coalesce(nullif(v_clean, ''), public.files_revision_title(v_d.sequence));
  end if;

  update public.deliveries
     set state = 'delivered', delivered_at = now(), expires_at = public.files_expires_at(now()),
         title = v_title, note = coalesce(v_note, '')
   where id = v_d.id;

  if v_d.kind = 'delivery' then
    update public.bookings
       set delivered_at = coalesce(delivered_at, now()),
           receipt_confirmed_at = coalesce(receipt_confirmed_at, now()),
           status = case when total_cents - deposit_cents <= 0 and status = 'confirmed' then 'completed'::public.booking_status else status end
     where id = v_b.id;
  end if;

  if exists (select 1 from public.organizations o where o.id = v_b.creator_id) then
    perform public.activity_add(v_b.creator_id, 'files.delivered', 'booking', v_b.id,
      case when v_d.kind = 'delivery' then 'Delivered ' else 'Sent a revision of ' end
      || v_ready || (case when v_ready = 1 then ' file for ' else ' files for ' end)
      || v_b.package_name || ' (' || coalesce(nullif(v_b.client_name, ''), 'a client') || ')');
  end if;
  return public.list_booking_files(v_b.id);
end;
$$;

-- Takes a file away (before or after delivery). Frees its space and queues its bytes for deletion.
create or replace function public.files_remove(p_file_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_f   public.delivery_files;
  v_b   public.bookings;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_f from public.delivery_files where id = p_file_id for update;
  if not found then
    raise exception 'not_found';
  end if;
  select * into v_b from public.bookings where id = v_f.booking_id;
  if not public.provider_access(v_uid, v_b.creator_id, v_b.assigned_to, 'manage') or v_f.status not in ('uploading', 'ready') then
    raise exception 'not_found';
  end if;
  update public.delivery_files set status = 'removed', removed_at = now(), removed_by = v_uid where id = v_f.id;
  insert into public.storage_purge (path) values (v_f.original_path), (v_f.preview_path) on conflict do nothing;
  if exists (select 1 from public.organizations o where o.id = v_b.creator_id) then
    perform public.activity_add(v_b.creator_id, 'files.removed', 'booking', v_b.id,
      'Removed a file from ' || v_b.package_name || ' (' || coalesce(nullif(v_b.client_name, ''), 'a client') || ')',
      jsonb_build_object('name', v_f.name));
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- The client: saving, and reporting
-- ---------------------------------------------------------------------------
-- The client saved an original. Only counts once it is theirs to open. Returns how many of the delivery are saved.
create or replace function public.files_mark_saved(p_file_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_f   public.delivery_files;
  v_d   public.deliveries;
  v_b   public.bookings;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_f from public.delivery_files where id = p_file_id for update;
  if not found then
    raise exception 'not_found';
  end if;
  select * into v_b from public.bookings where id = v_f.booking_id;
  if v_b.client_id is distinct from v_uid or v_f.status <> 'ready' then
    raise exception 'not_found';
  end if;
  select * into v_d from public.deliveries where id = v_f.delivery_id;
  if not public.files_can_open('original', 'client', v_d.kind, v_d.state, v_d.expires_at, public.booking_owed_cents(v_b.id)) then
    raise exception 'originals_locked';
  end if;
  update public.delivery_files set saved_at = coalesce(saved_at, now()) where id = v_f.id;
  return (select jsonb_build_object('saved', count(*) filter (where saved_at is not null), 'total', count(*))
            from public.delivery_files where delivery_id = v_d.id and status = 'ready');
end;
$$;

-- Either person on the booking can report a file. Reports go to the support console (R16).
create or replace function public.files_report(p_file_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid    uuid := auth.uid();
  v_f      public.delivery_files;
  v_b      public.bookings;
  v_reason text := left(coalesce(public.message_clean(p_reason), ''), 500);
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_f from public.delivery_files where id = p_file_id;
  if not found then
    raise exception 'not_found';
  end if;
  select * into v_b from public.bookings where id = v_f.booking_id;
  if v_f.status not in ('uploading', 'ready')
     or not (v_b.client_id is not distinct from v_uid or public.provider_access(v_uid, v_b.creator_id, v_b.assigned_to, 'manage')) then
    raise exception 'not_found';
  end if;
  insert into public.file_reports (file_id, booking_id, reporter_id, reason)
  values (v_f.id, v_b.id, v_uid, coalesce(nullif(v_reason, ''), 'No reason given'));
end;
$$;

-- ---------------------------------------------------------------------------
-- Reading: what the person looking is allowed to see
-- ---------------------------------------------------------------------------
-- The creator side sees every delivery, draft included, and the allowance. The client sees deliveries that were made (and
-- have since expired) and only paths they may open. A Viewer sees nothing, because client work is private.
create or replace function public.list_booking_files(p_booking_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid      uuid := auth.uid();
  v_b        public.bookings;
  v_provider boolean;
  v_owed     integer;
  v_first    public.deliveries;
  v_can      boolean;
  v_out      jsonb;
begin
  if v_uid is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  select * into v_b from public.bookings where id = p_booking_id;
  v_provider := found and public.provider_access(v_uid, v_b.creator_id, v_b.assigned_to, 'manage');
  if not found or not (v_provider or v_b.client_id is not distinct from v_uid) then
    raise exception 'not_found';
  end if;
  v_owed := public.booking_owed_cents(v_b.id);
  select * into v_first from public.deliveries where booking_id = v_b.id and sequence = 0;
  v_can := v_provider and v_b.status in ('confirmed', 'completed') and v_b.start_at <= now();

  select coalesce(jsonb_agg(d_json order by (d_json ->> 'sequence')::integer), '[]'::jsonb) into v_out
  from (
    select jsonb_build_object(
      'id', d.id, 'booking_id', d.booking_id, 'kind', d.kind, 'sequence', d.sequence, 'title', d.title, 'note', d.note,
      'state', d.state, 'created_at', d.created_at, 'delivered_at', d.delivered_at, 'expires_at', d.expires_at,
      'originals_open', public.files_can_open('original', case when v_provider then 'provider' else 'client' end,
                                              d.kind, d.state, d.expires_at, v_owed),
      'files', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', f.id, 'kind', f.kind, 'name', f.name, 'content_type', f.content_type, 'width', f.width, 'height', f.height,
          'duration_seconds', f.duration_seconds, 'original_bytes', f.original_bytes, 'preview_bytes', f.preview_bytes,
          'status', f.status, 'saved_at', f.saved_at, 'created_at', f.created_at, 'position', f.position,
          'preview_path', f.preview_path,
          'original_path', case when public.files_can_open('original', case when v_provider then 'provider' else 'client' end,
                                                           d.kind, d.state, d.expires_at, v_owed) then f.original_path end)
          order by f.position, f.created_at)
          from public.delivery_files f
         where f.delivery_id = d.id
           and f.status in (case when v_provider then 'uploading' else 'ready' end, 'ready', 'expired')), '[]'::jsonb)
    ) as d_json
    from public.deliveries d
    where d.booking_id = v_b.id and (v_provider or d.state in ('delivered', 'expired'))
  ) s;

  return jsonb_build_object(
    'booking_id', v_b.id,
    'owed_cents', v_owed,
    'deliveries', v_out,
    'used_bytes', case when v_provider then public.files_owner_used_bytes(v_b.creator_id) end,
    'allowance_bytes', case when v_provider then public.files_owner_allowance_bytes(v_b.creator_id) end,
    'can_deliver_files', coalesce(v_can and (v_first.state is null or v_first.state = 'draft')
                                  and not public.files_first_delivery_locked(false, v_b.delivery_url is not null or v_b.receipt_confirmed_at is not null, public.files_balance_paid(v_b.id)), false),
    'can_send_revision', coalesce(v_can and public.files_revision_allowed(v_first.state, v_owed), false)
  );
end;
$$;

-- "4.2 of 25 GB used", for the account on screen: a person's own, or a company's for anyone in it.
create or replace function public.files_storage_usage(p_owner uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_signed_in' using errcode = '28000';
  end if;
  if not public.acts_for(p_owner, 'team.view') then
    raise exception 'not_found';
  end if;
  return jsonb_build_object('used_bytes', public.files_owner_used_bytes(p_owner), 'allowance_bytes', public.files_owner_allowance_bytes(p_owner));
end;
$$;

-- ---------------------------------------------------------------------------
-- The scheduled job (service role only)
-- ---------------------------------------------------------------------------
-- Ends deliveries whose time is up, tidies drafts and uploads that never finished, and warns clients whose files are about
-- to go. Safe to run twice. Returns what it did; the bytes are deleted by files_purge_pending / files_purge_done.
create or replace function public.files_expire_due()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_d       record;
  v_b       public.bookings;
  v_expired integer := 0;
  v_drafts  integer := 0;
  v_lapsed  integer := 0;
  v_warned  integer := 0;
  v_day     integer;
  v_unsaved integer;
  v_total   integer;
begin
  -- The time is up.
  for v_d in select id from public.deliveries where state = 'delivered' and expires_at <= now() order by expires_at, id for update skip locked loop
    update public.deliveries set state = 'expired', expired_at = now() where id = v_d.id;
    with gone as (
      update public.delivery_files set status = 'expired' where delivery_id = v_d.id and status = 'ready'
      returning original_path, preview_path)
    insert into public.storage_purge (path)
      select p.path from gone g, lateral (values (g.original_path), (g.preview_path)) as p (path)
      on conflict do nothing;
    v_expired := v_expired + 1;
  end loop;

  -- A draft nobody delivered within draft_days goes (its files with it, and their bytes via the purge queue).
  with gone as (
    delete from public.deliveries
     where state = 'draft' and created_at < now() - make_interval(days => public.files_setting_int('draft_days', 7))
    returning id)
  select count(*) into v_drafts from gone;

  -- A reservation that never finished uploading gives its space back.
  with lapsed as (
    update public.delivery_files
       set status = 'removed', removed_at = now()
     where status = 'uploading' and created_at < now() - make_interval(hours => public.files_setting_int('reservation_hours', 24))
    returning original_path, preview_path),
  queued as (
    insert into public.storage_purge (path)
      select p.path from lapsed l, lateral (values (l.original_path), (l.preview_path)) as p (path)
      on conflict do nothing
    returning 1)
  select count(*) into v_lapsed from lapsed;

  -- Tell the client the files are about to go, once for each reminder day, while anything is unsaved.
  for v_d in
    select d.id, d.booking_id, d.kind, d.title, d.expires_at from public.deliveries d
     where d.state = 'delivered' and d.expires_at > now()
  loop
    v_day := public.files_reminder_day(v_d.expires_at);
    continue when v_day is null;
    select count(*) filter (where saved_at is null), count(*) into v_unsaved, v_total
      from public.delivery_files where delivery_id = v_d.id and status = 'ready';
    continue when v_unsaved = 0;
    select * into v_b from public.bookings where id = v_d.booking_id;
    if public.push_enqueue(v_b.client_id, 'files_expiring', v_b.id, jsonb_build_object(
         'bookingId', v_b.id, 'role', 'client', 'creatorName', v_b.creator_name, 'packageName', v_b.package_name,
         'revised', v_d.kind = 'revision', 'title', v_d.title, 'days', v_day, 'unsaved', v_unsaved, 'total', v_total,
         'balanceCents', public.booking_owed_cents(v_b.id), 'currency', v_b.currency_code),
         'files_expiring:' || v_d.id || ':' || v_day) then
      v_warned := v_warned + 1;
    end if;
  end loop;

  return jsonb_build_object('expired', v_expired, 'drafts_removed', v_drafts, 'uploads_lapsed', v_lapsed, 'warned', v_warned);
end;
$$;

-- The next batch of objects to delete from storage.
create or replace function public.files_purge_pending(p_limit integer default 200)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(array_agg(path), '{}'::text[])
    from (select path from public.storage_purge order by queued_at, path limit greatest(1, least(coalesce(p_limit, 200), 1000))) s;
$$;

-- Those objects are gone from storage.
create or replace function public.files_purge_done(p_paths text[])
returns integer
language sql
security definer
set search_path = public
as $$
  with gone as (delete from public.storage_purge where path = any (coalesce(p_paths, '{}'::text[])) returning 1)
  select count(*)::integer from gone;
$$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
-- Everything is closed to the API roles unless re-opened below. (Functions are executable by everyone by default.)
revoke execute on function
  public.files_expire_due(),
  public.files_purge_pending(integer),
  public.files_purge_done(text[]),
  public.delivery_files_queue_purge(),
  public.deliveries_notify_delivered(),
  public.deliveries_notify_expired(),
  -- What a booking owes and how full a place is are answered through the functions below, to the right people only.
  public.booking_owed_cents(uuid),
  public.files_owner_used_bytes(uuid),
  public.files_owner_allowance_bytes(uuid),
  public.files_balance_paid(uuid)
from public, anon, authenticated;

revoke execute on function
  public.files_reserve(uuid, text, text, text, integer, integer, numeric, bigint, bigint),
  public.files_finalize(uuid),
  public.files_deliver(uuid, text, text),
  public.files_remove(uuid),
  public.files_mark_saved(uuid),
  public.files_report(uuid, text),
  public.list_booking_files(uuid),
  public.files_storage_usage(uuid)
from public, anon;
grant execute on function
  public.files_reserve(uuid, text, text, text, integer, integer, numeric, bigint, bigint),
  public.files_finalize(uuid),
  public.files_deliver(uuid, text, text),
  public.files_remove(uuid),
  public.files_mark_saved(uuid),
  public.files_report(uuid, text),
  public.list_booking_files(uuid),
  public.files_storage_usage(uuid)
to authenticated;

-- The numbers are not secret, and the app needs them before anyone is signed in to a booking.
grant execute on function public.files_config() to anon, authenticated;
-- The storage policies call these as the signed-in person.
revoke execute on function public.files_may_store(text), public.files_may_read(text) from public, anon;
grant execute on function public.files_may_store(text), public.files_may_read(text) to authenticated;
