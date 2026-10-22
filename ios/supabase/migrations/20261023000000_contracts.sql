-- Contracts: templates with placeholders, the creator's saved signature, signed contracts, and their PDFs.
--
-- The rule this migration exists to enforce: a client signs a *hash of the text the server produced*.
-- The client never supplies contract text. create_booking() re-renders the contract from the creator's
-- template and the booking's own data and refuses ('contract_changed') if its hash differs from the one
-- the client signed. Otherwise a tampered contract could be countersigned automatically by the creator.
--
-- The renderer here (contract_fill, contract_values and friends) must produce exactly the same text as the
-- Swift ContractRenderer. Both are tested against ios/SlateTests/Fixtures/contract_golden.json.

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------------
-- Field lists (closed sets, shared with the app's ContractField)
-- ---------------------------------------------------------------------------
create or replace function public.contract_known_fields()
returns text[]
language sql
immutable
as $$
  select array[
    'client_name', 'creator_name', 'package_name', 'booking_date', 'booking_time', 'time_zone',
    'duration', 'deliverables', 'add_ons', 'price', 'deposit', 'balance', 'turnaround',
    'delivery_date', 'cancellation_policy', 'usage_rights', 'client_notes'
  ];
$$;

create or replace function public.contract_required_fields()
returns text[]
language sql
immutable
as $$
  select array['client_name', 'creator_name', 'package_name', 'booking_date', 'price', 'cancellation_policy'];
$$;

-- Names inside {{...}}, in order of appearance.
create or replace function public.contract_tokens(p_text text)
returns text[]
language sql
immutable
as $$
  select coalesce(array_agg(m[1]), '{}'::text[])
    from regexp_matches(coalesce(p_text, ''), '\{\{(.*?)\}\}', 'g') as m;
$$;

-- ---------------------------------------------------------------------------
-- Canonical formatting (no locale involved)
-- ---------------------------------------------------------------------------
create or replace function public.contract_money(p_cents integer, p_code text)
returns text
language sql
immutable
as $$
  select case when p_cents < 0 then '-' else '' end
      || case when p_code = 'USD' then '$' else p_code || ' ' end
      || case when abs(p_cents) % 100 = 0
              then trim(to_char(abs(p_cents) / 100, 'FM999,999,999,990'))
              else trim(to_char(abs(p_cents) / 100.0, 'FM999,999,999,990.00'))
         end;
$$;

create or replace function public.contract_long_date(p_day date)
returns text
language sql
immutable
as $$
  select (array['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'])[extract(dow from p_day)::integer + 1]
      || ', '
      || (array['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'])[extract(month from p_day)::integer]
      || ' ' || extract(day from p_day)::integer::text
      || ', ' || extract(year from p_day)::integer::text;
$$;

-- "9:05 AM", "12:00 PM"
create or replace function public.contract_time(p_local timestamp)
returns text
language sql
immutable
as $$
  select (case when extract(hour from p_local)::integer % 12 = 0 then 12 else extract(hour from p_local)::integer % 12 end)::text
      || ':' || lpad(extract(minute from p_local)::integer::text, 2, '0')
      || ' ' || case when extract(hour from p_local)::integer < 12 then 'AM' else 'PM' end;
$$;

create or replace function public.contract_duration(p_minutes integer)
returns text
language sql
immutable
as $$
  select case
           when p_minutes / 60 > 0 and p_minutes % 60 > 0
             then (p_minutes / 60)::text || ' hour' || case when p_minutes / 60 = 1 then '' else 's' end
               || ' ' || (p_minutes % 60)::text || ' minute' || case when p_minutes % 60 = 1 then '' else 's' end
           when p_minutes / 60 > 0
             then (p_minutes / 60)::text || ' hour' || case when p_minutes / 60 = 1 then '' else 's' end
           else (p_minutes % 60)::text || ' minute' || case when p_minutes % 60 = 1 then '' else 's' end
         end;
$$;

create or replace function public.contract_days(p_count integer)
returns text
language sql
immutable
as $$
  select p_count::text || ' day' || case when p_count = 1 then '' else 's' end;
$$;

-- Makes a person-supplied string safe to put in a contract. Mirrors ContractFormat.sanitize.
--   * No two braces in a row survive ("{{{" becomes "{ { {"), so a value can never open or close a placeholder.
--   * Whitespace means ASCII whitespace only (never the locale's idea of it), so every device and the
--     server agree. Unless line breaks are wanted it collapses to single spaces; if they are, CRLF and CR become LF.
create or replace function public.contract_sanitize(p_value text, p_keep_breaks boolean default false)
returns text
language sql
immutable
as $$
  select btrim(
    case when p_keep_breaks
         then regexp_replace(spaced, E'\r\n?', E'\n', 'g')
         else regexp_replace(spaced, '[ \t\n\r\f\v]+', ' ', 'g')
    end,
    E' \t\n\r\f' || chr(11)
  )
  from (
    select regexp_replace(
             regexp_replace(coalesce(p_value, ''), '\{(?=\{)', '{ ', 'g'),
             '\}(?=\})', '} ', 'g'
           ) as spaced
  ) s;
$$;

-- The exact words that go into a contract. These mirror CancellationPolicy.contractText / UsageRights.contractText.
create or replace function public.contract_policy_text(p_policy text)
returns text
language sql
immutable
as $$
  select case p_policy
    when 'flexible' then 'Flexible. If the Client cancels at least 24 hours before the shoot, the Client receives a full refund of the amounts paid. If the Client cancels later, the Client receives a 50% refund. If the Creator cancels, the Client receives a full refund.'
    when 'moderate' then 'Moderate. If the Client cancels at least 7 days before the shoot, the Client receives a full refund of the amounts paid. If the Client cancels at least 48 hours before the shoot, the Client receives a 50% refund. After that, no refund is due. If the Creator cancels, the Client receives a full refund.'
    when 'strict' then 'Strict. If the Client cancels at least 14 days before the shoot, the Client receives a 50% refund of the amounts paid. After that, no refund is due. If the Creator cancels, the Client receives a full refund.'
  end;
$$;

create or replace function public.contract_rights_text(p_rights text)
returns text
language sql
immutable
as $$
  select case p_rights
    when 'personal' then 'Personal use. The Client may use the deliverables for personal, non-commercial purposes, such as prints, albums and sharing with family and friends. The Creator keeps the copyright and may show the work in their portfolio and promotion.'
    when 'personalSocial' then 'Personal and social media use. The Client may use the deliverables for personal, non-commercial purposes and may post them on the Client''s own social media accounts, crediting the Creator. The Creator keeps the copyright and may show the work in their portfolio and promotion.'
    when 'commercial' then 'Commercial use. The Client may use the deliverables to promote the Client''s own business, including on websites, social media and advertising. The Client may not resell the deliverables or license them to others. The Creator keeps the copyright and may show the work in their portfolio and promotion.'
    when 'fullTransfer' then 'Full rights transfer. Copyright in the deliverables passes to the Client once the Client has paid in full. The Creator may still show the work in their portfolio and promotion unless the Client asks otherwise in writing.'
  end;
$$;

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------
-- Replaces each {{token}} once, in a single pass, so a value can never be re-read as a placeholder.
-- Unknown tokens are left exactly as written.
create or replace function public.contract_fill(p_text text, p_values jsonb)
returns text
language plpgsql
immutable
as $$
declare
  v_out text := '';
  v_rest text := coalesce(p_text, '');
  v_open integer;
  v_close integer;
  v_name text;
begin
  loop
    v_open := position('{{' in v_rest);
    exit when v_open = 0;
    v_close := position('}}' in substr(v_rest, v_open + 2));
    exit when v_close = 0;

    v_out := v_out || substr(v_rest, 1, v_open - 1);
    v_name := substr(v_rest, v_open + 2, v_close - 1);
    if p_values ? v_name then
      v_out := v_out || (p_values ->> v_name);
    else
      v_out := v_out || '{{' || v_name || '}}';
    end if;
    v_rest := substr(v_rest, v_open + v_close + 3);
  end loop;
  return v_out || v_rest;
end;
$$;

-- Every value a template can use, for one booking. p_chosen is the array of chosen add-on objects.
create or replace function public.contract_values(
  p_pkg          public.packages,
  p_chosen       jsonb,
  p_start        timestamptz,
  p_tz           text,
  p_client_name  text,
  p_creator_name text,
  p_notes        text
)
returns jsonb
language plpgsql
stable
as $$
declare
  v_extra_minutes integer := coalesce((select sum(coalesce((e ->> 'extraMinutes')::integer, 0)) from jsonb_array_elements(p_chosen) e), 0);
  v_add_on_total  integer := coalesce((select sum(coalesce((e ->> 'priceCents')::integer, 0)) from jsonb_array_elements(p_chosen) e), 0);
  v_delta         integer := coalesce((select sum(coalesce((e ->> 'turnaroundDeltaDays')::integer, 0)) from jsonb_array_elements(p_chosen) e), 0);
  v_duration      integer := p_pkg.duration_minutes + v_extra_minutes;
  v_turnaround    integer := greatest(1, p_pkg.turnaround_days + v_delta);
  v_total         integer := p_pkg.price_cents + v_add_on_total;
  v_deposit       integer := least(p_pkg.deposit_cents, v_total);
  v_local_start   timestamp := p_start at time zone p_tz;
  v_local_end     timestamp := (p_start + make_interval(mins => v_duration)) at time zone p_tz;
  v_deliverables  text;
  v_add_ons       text;
  v_client        text := public.contract_sanitize(p_client_name);
  v_notes         text := public.contract_sanitize(p_notes, true);
begin
  select coalesce(string_agg('• ' || public.contract_sanitize(d), E'\n' order by ord), 'As described in the package')
    into v_deliverables
    from unnest(p_pkg.deliverables) with ordinality as t(d, ord);

  select coalesce(string_agg('• ' || public.contract_sanitize(e ->> 'name') || ' (+' || public.contract_money(coalesce((e ->> 'priceCents')::integer, 0), p_pkg.currency_code) || ')', E'\n' order by ord), 'None')
    into v_add_ons
    from jsonb_array_elements(p_chosen) with ordinality as t(e, ord);

  return jsonb_build_object(
    'client_name', case when v_client = '' then 'the Client' else v_client end,
    'creator_name', public.contract_sanitize(p_creator_name),
    'package_name', public.contract_sanitize(p_pkg.name),
    'booking_date', public.contract_long_date(v_local_start::date),
    'booking_time', public.contract_time(v_local_start) || ' – ' || public.contract_time(v_local_end),
    'time_zone', p_tz,
    'duration', public.contract_duration(v_duration),
    'deliverables', v_deliverables,
    'add_ons', v_add_ons,
    'price', public.contract_money(v_total, p_pkg.currency_code),
    'deposit', public.contract_money(v_deposit, p_pkg.currency_code),
    'balance', public.contract_money(v_total - v_deposit, p_pkg.currency_code),
    'turnaround', public.contract_days(v_turnaround),
    'delivery_date', public.contract_long_date(v_local_start::date + v_turnaround),
    'cancellation_policy', public.contract_policy_text(p_pkg.cancellation_policy),
    'usage_rights', public.contract_rights_text(p_pkg.usage_rights),
    'client_notes', case when v_notes = '' then 'None' else v_notes end
  );
end;
$$;

-- A template with its values filled in: { title, sections, text, document_hash, template_id, template_version }.
create or replace function public.contract_render(p_title text, p_clauses jsonb, p_values jsonb, p_template_id uuid, p_version integer)
returns jsonb
language plpgsql
immutable
as $$
declare
  v_title text := public.contract_fill(p_title, p_values);
  v_sections jsonb := '[]'::jsonb;
  v_parts text[];
  v_clause jsonb;
  v_index integer := 0;
  v_section_title text;
  v_section_body text;
  v_text text;
begin
  v_parts := array[v_title];
  for v_clause in select value from jsonb_array_elements(p_clauses) loop
    v_index := v_index + 1;
    v_section_title := public.contract_fill(v_clause ->> 'title', p_values);
    v_section_body := public.contract_fill(v_clause ->> 'body', p_values);
    v_sections := v_sections || jsonb_build_array(jsonb_build_object('title', v_section_title, 'body', v_section_body));
    v_parts := v_parts || (v_index::text || '. ' || v_section_title || E'\n' || v_section_body);
  end loop;

  v_text := array_to_string(v_parts, E'\n\n');
  return jsonb_build_object(
    'title', v_title,
    'sections', v_sections,
    'text', v_text,
    'document_hash', encode(extensions.digest(convert_to(v_text, 'UTF8'), 'sha256'), 'hex'),
    'template_id', p_template_id,
    'template_version', p_version
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- contract_templates
-- ---------------------------------------------------------------------------
create table public.contract_templates (
  id         uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.creator_profiles (id) on delete cascade,
  title      text not null,
  kind       text not null check (kind in ('photography', 'videography', 'freelance', 'custom')),
  -- [{ "id", "title", "body" }], in reading order.
  clauses    jsonb not null,
  -- Goes up whenever the wording changes. Signed contracts keep the version they were signed on.
  version    integer not null default 1,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index contract_templates_creator_idx on public.contract_templates (creator_id, created_at);

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
    new.creator_id := old.creator_id;
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

create trigger contract_templates_validate
  before insert or update on public.contract_templates
  for each row execute function public.validate_contract_template();

alter table public.contract_templates enable row level security;

-- Templates are private to their creator. Clients see only the rendered result, through preview_contract().
create policy "Creators read their own contracts"
  on public.contract_templates for select
  to authenticated
  using ((select auth.uid()) = creator_id);

create policy "Creators add their own contracts"
  on public.contract_templates for insert
  to authenticated
  with check ((select auth.uid()) = creator_id);

create policy "Creators edit their own contracts"
  on public.contract_templates for update
  to authenticated
  using ((select auth.uid()) = creator_id)
  with check ((select auth.uid()) = creator_id);

create policy "Creators delete their own contracts"
  on public.contract_templates for delete
  to authenticated
  using ((select auth.uid()) = creator_id);

-- ---------------------------------------------------------------------------
-- creator_signatures: the signature applied to each contract when a client books
-- ---------------------------------------------------------------------------
create table public.creator_signatures (
  creator_id  uuid primary key references public.creator_profiles (id) on delete cascade,
  signed_name text not null check (char_length(btrim(signed_name)) between 2 and 80),
  method      text not null check (method in ('typed', 'drawn')),
  -- Base64 PNG of a drawn signature.
  image_png   text check (char_length(image_png) <= 400000),
  updated_at  timestamptz not null default now(),
  constraint drawn_needs_image check (method <> 'drawn' or image_png is not null)
);

create trigger creator_signatures_set_updated_at
  before update on public.creator_signatures
  for each row execute function public.set_updated_at();

alter table public.creator_signatures enable row level security;

create policy "Creators read their own signature"
  on public.creator_signatures for select
  to authenticated
  using ((select auth.uid()) = creator_id);

create policy "Creators add their own signature"
  on public.creator_signatures for insert
  to authenticated
  with check ((select auth.uid()) = creator_id);

create policy "Creators change their own signature"
  on public.creator_signatures for update
  to authenticated
  using ((select auth.uid()) = creator_id)
  with check ((select auth.uid()) = creator_id);

-- ---------------------------------------------------------------------------
-- packages: which contract, cancellation policy and usage rights
-- ---------------------------------------------------------------------------
alter table public.packages
  add column contract_template_id uuid references public.contract_templates (id) on delete restrict,
  add column cancellation_policy text not null default 'moderate' check (cancellation_policy in ('flexible', 'moderate', 'strict')),
  add column usage_rights text not null default 'personal' check (usage_rights in ('personal', 'personalSocial', 'commercial', 'fullTransfer'));

-- A visible package must have a contract. NOT VALID so packages that predate contracts don't block the migration;
-- the rule applies to every new or edited package.
alter table public.packages
  add constraint published_needs_contract check (not is_published or contract_template_id is not null) not valid;

create or replace function public.check_package_template_owner()
returns trigger
language plpgsql
as $$
begin
  if new.contract_template_id is not null
     and not exists (select 1 from public.contract_templates t where t.id = new.contract_template_id and t.creator_id = new.creator_id) then
    raise exception 'invalid_contract: that contract belongs to someone else';
  end if;
  return new;
end;
$$;

create trigger packages_check_template_owner
  before insert or update on public.packages
  for each row execute function public.check_package_template_owner();

-- ---------------------------------------------------------------------------
-- contracts and signatures
-- ---------------------------------------------------------------------------
create type public.contract_status as enum ('pending', 'executed', 'voided');

create table public.contracts (
  id               uuid primary key default gen_random_uuid(),
  booking_id       uuid not null unique references public.bookings (id) on delete cascade,
  creator_id       uuid not null references public.creator_profiles (id) on delete cascade,
  client_id        uuid references auth.users (id) on delete set null,
  template_id      uuid references public.contract_templates (id) on delete set null,
  template_version integer not null,
  title            text not null,
  sections         jsonb not null,
  -- SHA-256 (hex) of the exact text that was signed.
  document_hash    text not null check (document_hash ~ '^[0-9a-f]{64}$'),
  status           public.contract_status not null default 'executed',
  created_at       timestamptz not null default now(),
  executed_at      timestamptz
);

create index contracts_creator_idx on public.contracts (creator_id);
create index contracts_client_idx on public.contracts (client_id);

create table public.contract_signatures (
  id              uuid primary key default gen_random_uuid(),
  contract_id     uuid not null references public.contracts (id) on delete cascade,
  role            text not null check (role in ('creator', 'client')),
  user_id         uuid references auth.users (id) on delete set null,
  signed_name     text not null,
  method          text not null check (method in ('typed', 'drawn', 'onFile')),
  image_png       text,
  signed_at       timestamptz not null default now(),
  consent_version integer not null,
  device          text not null default '',
  -- Best effort, from the proxy's forwarded-for header.
  ip              text,
  unique (contract_id, role)
);

alter table public.contracts enable row level security;
alter table public.contract_signatures enable row level security;

-- Written only by create_booking(). The two people on a booking can read it; nobody can edit it.
create policy "Parties read their contract"
  on public.contracts for select
  to authenticated
  using ((select auth.uid()) = client_id or (select auth.uid()) = creator_id);

create policy "Parties read the signatures on their contract"
  on public.contract_signatures for select
  to authenticated
  using (exists (
    select 1 from public.contracts c
     where c.id = contract_id and ((select auth.uid()) = c.client_id or (select auth.uid()) = c.creator_id)
  ));

-- ---------------------------------------------------------------------------
-- Signed PDFs: a private bucket, readable and addable only by the two parties on that contract.
-- The file name is the contract id, and a stored PDF can't be overwritten, so both people keep the same file.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('contracts', 'contracts', false, 5242880, array['application/pdf'])
on conflict (id) do nothing;

create policy "Parties read their signed PDF"
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'contracts'
    and exists (
      select 1 from public.contracts c
       where c.id::text || '.pdf' = name
         and ((select auth.uid()) = c.client_id or (select auth.uid()) = c.creator_id)
    )
  );

create policy "Parties store their signed PDF once"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'contracts'
    and exists (
      select 1 from public.contracts c
       where c.id::text || '.pdf' = name
         and ((select auth.uid()) = c.client_id or (select auth.uid()) = c.creator_id)
    )
  );

-- ---------------------------------------------------------------------------
-- contract_prepare: everything create_booking and preview_contract share
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
  v_creator_name  text;
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
  if v_pkg.creator_id = v_uid then
    raise exception 'cannot_book_yourself';
  end if;

  select * into v_template from public.contract_templates where id = v_pkg.contract_template_id;
  if not found then
    raise exception 'contract_missing';
  end if;
  if not exists (select 1 from public.creator_signatures where creator_id = v_pkg.creator_id) then
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

  select display_name into v_creator_name from public.creator_profiles where id = v_pkg.creator_id;
  v_values := public.contract_values(v_pkg, v_chosen, p_start_at, v_settings.time_zone, p_client_name, coalesce(v_creator_name, 'Creator'), p_notes);

  return jsonb_build_object(
    'package_id', v_pkg.id,
    'creator_id', v_pkg.creator_id,
    'creator_name', coalesce(v_creator_name, 'Creator'),
    'chosen', v_chosen,
    'rendered', public.contract_render(v_template.title, v_template.clauses, v_values, v_template.id, v_template.version)
  );
end;
$$;

-- What a client sees before signing. Returns { title, sections, text, document_hash, template_id, template_version }.
create or replace function public.preview_contract(
  p_package_id   uuid,
  p_add_on_ids   uuid[],
  p_start_at     timestamptz,
  p_client_name  text default '',
  p_notes        text default ''
)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.contract_prepare(p_package_id, p_add_on_ids, p_start_at, p_client_name, p_notes) -> 'rendered';
$$;

-- ---------------------------------------------------------------------------
-- create_booking v2: book and sign in one step
-- ---------------------------------------------------------------------------
-- Replaces the version from the previous migration. Additional error tokens:
--   contract_changed, invalid_signature
drop function public.create_booking(uuid, uuid[], timestamptz, text, text);

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

  select * into v_pkg from public.packages where id = p_package_id;
  select * into v_settings from public.availability_settings where creator_id = v_pkg.creator_id;

  select coalesce(sum(coalesce((e ->> 'extraMinutes')::integer, 0)), 0), coalesce(sum(coalesce((e ->> 'priceCents')::integer, 0)), 0)
    into v_extra_minutes, v_add_on_total
    from jsonb_array_elements(v_chosen) e;

  v_duration := v_pkg.duration_minutes + v_extra_minutes;
  v_end := p_start_at + make_interval(mins => v_duration);
  v_blocked_until := v_end + make_interval(mins => v_settings.buffer_minutes);

  -- Local wall-clock time in the creator's zone; every availability rule is expressed in it.
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

  -- Only a typed or drawn signature can come from a client. 'onFile' is applied below, from the creator's own record.
  if char_length(v_sig_name) not between 2 and 80
     or v_sig_method not in ('typed', 'drawn')
     or (v_sig_method = 'drawn' and (v_sig_image is null or char_length(v_sig_image) > 400000 or char_length(v_sig_image) = 0)) then
    raise exception 'invalid_signature';
  end if;

  -- They must have signed the exact words we would produce now.
  if p_document_hash is distinct from (v_rendered ->> 'document_hash') then
    raise exception 'contract_changed';
  end if;

  v_total := v_pkg.price_cents + v_add_on_total;
  v_deposit := least(v_pkg.deposit_cents, v_total);

  begin
    insert into public.bookings (
      creator_id, client_id, creator_name, client_name, package_id, package_name, add_ons,
      start_at, end_at, blocked_until, time_zone, currency_code, total_cents, deposit_cents,
      status, notes
    ) values (
      v_pkg.creator_id, v_uid, v_prep ->> 'creator_name', left(coalesce(p_client_name, ''), 80),
      v_pkg.id, v_pkg.name,
      coalesce((select jsonb_agg(jsonb_build_object(
          'id', e ->> 'id', 'name', e ->> 'name',
          'priceCents', coalesce((e ->> 'priceCents')::integer, 0),
          'extraMinutes', coalesce((e ->> 'extraMinutes')::integer, 0)))
        from jsonb_array_elements(v_chosen) e), '[]'::jsonb),
      p_start_at, v_end, v_blocked_until, v_settings.time_zone, v_pkg.currency_code, v_total, v_deposit,
      'confirmed', left(coalesce(p_notes, ''), 500)
    )
    returning * into v_booking;
  exception
    when exclusion_violation then
      -- Another booking overlaps. This is what protects against two simultaneous requests.
      raise exception 'slot_taken';
  end;

  select * into v_creator_sig from public.creator_signatures where creator_id = v_pkg.creator_id;
  v_ip := nullif(btrim(split_part(coalesce(nullif(current_setting('request.headers', true), '')::jsonb ->> 'x-forwarded-for', ''), ',', 1)), '');

  insert into public.contracts (
    booking_id, creator_id, client_id, template_id, template_version, title, sections, document_hash, status, executed_at
  ) values (
    v_booking.id, v_pkg.creator_id, v_uid, (v_rendered ->> 'template_id')::uuid, (v_rendered ->> 'template_version')::integer,
    v_rendered ->> 'title', v_rendered -> 'sections', v_rendered ->> 'document_hash', 'executed', now()
  )
  returning * into v_contract;

  insert into public.contract_signatures (contract_id, role, user_id, signed_name, method, image_png, consent_version, device, ip)
  values
    (v_contract.id, 'client', v_uid, v_sig_name, v_sig_method,
     case when v_sig_method = 'drawn' then v_sig_image end,
     coalesce((p_signature ->> 'consentVersion')::integer, 1), left(coalesce(p_signature ->> 'device', ''), 200), v_ip),
    (v_contract.id, 'creator', v_pkg.creator_id, v_creator_sig.signed_name, 'onFile',
     case when v_creator_sig.method = 'drawn' then v_creator_sig.image_png end,
     1, 'Signature on file, applied at booking', null);

  return jsonb_build_object('booking', to_jsonb(v_booking), 'contract', public.contract_json(v_contract.id));
end;
$$;

-- A contract with its signatures, as the app reads it.
create or replace function public.contract_json(p_contract_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select to_jsonb(c) || jsonb_build_object(
           'signatures',
           coalesce((select jsonb_agg(to_jsonb(s) order by s.signed_at, s.role) from public.contract_signatures s where s.contract_id = c.id), '[]'::jsonb)
         )
    from public.contracts c
   where c.id = p_contract_id;
$$;

-- ---------------------------------------------------------------------------
-- Who may call what
-- ---------------------------------------------------------------------------
revoke execute on function public.contract_prepare(uuid, uuid[], timestamptz, text, text) from public, anon, authenticated;
revoke execute on function public.contract_json(uuid) from public, anon, authenticated;
revoke execute on function public.preview_contract(uuid, uuid[], timestamptz, text, text) from public, anon;
revoke execute on function public.create_booking(uuid, uuid[], timestamptz, text, text, text, jsonb) from public, anon;
grant execute on function public.preview_contract(uuid, uuid[], timestamptz, text, text) to authenticated;
grant execute on function public.create_booking(uuid, uuid[], timestamptz, text, text, text, jsonb) to authenticated;
