-- Creator profiles, portfolio items and their storage buckets.
--
-- Profiles are public by design (they are the page clients book from), so SELECT is open to
-- everyone. Every write is restricted to the owner through Row Level Security.

-- Shared trigger: keep updated_at honest.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- creator_profiles
-- ---------------------------------------------------------------------------
create table public.creator_profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  -- Mirrors HandleRules in the app: 3-30 chars, lowercase letters/digits/-/_, alphanumeric edges.
  handle           text not null unique
                     check (handle ~ '^[a-z0-9][a-z0-9_-]{1,28}[a-z0-9]$')
                     check (handle not in (
                       'admin', 'api', 'app', 'about', 'bookings', 'contracts', 'help', 'login',
                       'messages', 'privacy', 'profile', 'services', 'settings', 'signup',
                       'slate', 'support', 'terms', 'www'
                     )),
  display_name     text not null check (char_length(btrim(display_name)) between 1 and 80),
  bio              text not null default '' check (char_length(bio) <= 280),
  -- Raw values of the app's Specialty enum.
  specialties      text[] not null default '{}' check (cardinality(specialties) <= 5),
  -- City-level only. The app never stores street addresses.
  location_name    text check (char_length(location_name) <= 120),
  latitude         double precision check (latitude between -90 and 90),
  longitude        double precision check (longitude between -180 and 180),
  travel_radius_km integer check (travel_radius_km between 0 and 2000),
  -- Path inside the `avatars` bucket.
  avatar_path      text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

create trigger creator_profiles_set_updated_at
  before update on public.creator_profiles
  for each row execute function public.set_updated_at();

alter table public.creator_profiles enable row level security;

create policy "Profiles are public"
  on public.creator_profiles for select
  using (true);

create policy "Creators insert their own profile"
  on public.creator_profiles for insert
  to authenticated
  with check ((select auth.uid()) = id);

create policy "Creators update their own profile"
  on public.creator_profiles for update
  to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

create policy "Creators delete their own profile"
  on public.creator_profiles for delete
  to authenticated
  using ((select auth.uid()) = id);

-- ---------------------------------------------------------------------------
-- portfolio_items
-- ---------------------------------------------------------------------------
create table public.portfolio_items (
  id               uuid primary key default gen_random_uuid(),
  creator_id       uuid not null references public.creator_profiles (id) on delete cascade,
  kind             text not null check (kind in ('photo', 'video')),
  position         integer not null default 0 check (position >= 0),
  caption          text not null default '' check (char_length(caption) <= 140),
  -- Paths inside the `portfolio` bucket. For videos, image_path is the poster frame.
  image_path       text not null,
  thumbnail_path   text not null,
  video_path       text,
  duration_seconds double precision check (duration_seconds > 0),
  aspect_ratio     double precision not null default 1 check (aspect_ratio > 0),
  created_at       timestamptz not null default now(),
  constraint video_items_have_a_video check ((kind = 'video') = (video_path is not null))
);

create index portfolio_items_creator_position_idx
  on public.portfolio_items (creator_id, position);

-- The app caps portfolios at 12 pieces; enforce it where it can't be bypassed.
create or replace function public.enforce_portfolio_limit()
returns trigger
language plpgsql
as $$
begin
  if (select count(*) from public.portfolio_items where creator_id = new.creator_id) >= 12 then
    raise exception 'A portfolio can hold at most 12 items' using errcode = 'check_violation';
  end if;
  return new;
end;
$$;

create trigger portfolio_items_limit
  before insert on public.portfolio_items
  for each row execute function public.enforce_portfolio_limit();

alter table public.portfolio_items enable row level security;

create policy "Portfolios are public"
  on public.portfolio_items for select
  using (true);

create policy "Creators add to their own portfolio"
  on public.portfolio_items for insert
  to authenticated
  with check ((select auth.uid()) = creator_id);

create policy "Creators edit their own portfolio"
  on public.portfolio_items for update
  to authenticated
  using ((select auth.uid()) = creator_id)
  with check ((select auth.uid()) = creator_id);

create policy "Creators delete from their own portfolio"
  on public.portfolio_items for delete
  to authenticated
  using ((select auth.uid()) = creator_id);

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------
-- Both buckets are public-read: these images and reels are shown on public booking pages.
-- Writes are limited to a folder named after the signed-in user's id.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
  ('avatars',   'avatars',   true,   5242880, array['image/jpeg']),
  ('portfolio', 'portfolio', true, 262144000, array['image/jpeg', 'video/mp4', 'video/quicktime'])
on conflict (id) do nothing;

create policy "Creators upload to their own avatar folder"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "Creators replace their own avatar files"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "Creators delete their own avatar files"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "Creators upload to their own portfolio folder"
  on storage.objects for insert
  to authenticated
  with check (bucket_id = 'portfolio' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "Creators replace their own portfolio files"
  on storage.objects for update
  to authenticated
  using (bucket_id = 'portfolio' and (storage.foldername(name))[1] = (select auth.uid())::text);

create policy "Creators delete their own portfolio files"
  on storage.objects for delete
  to authenticated
  using (bucket_id = 'portfolio' and (storage.foldername(name))[1] = (select auth.uid())::text);
