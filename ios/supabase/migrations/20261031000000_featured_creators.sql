-- Featured creators: the explore grid under the search box on a client's Home.
--
-- Not paid placement and not hand-picked: it is worked out from what the platform already knows, so it is the same
-- for everyone and nobody can buy a place in it. A creator is a candidate when a client could book them (at least one
-- published package). Candidates are ordered by
--
--   1. when the client has chosen a place (p_lat and p_lon, city-level), creators who work there: the client is
--      inside the area they travel to, so the distance from the client to the creator's city is no more than their
--      travel radius (40 km when a profile has none). With no place nobody does, and this changes nothing;
--   2. those with something to look at (at least one portfolio piece) first;
--   3. a smoothed average rating, (sum of ratings + 12) / (reviews + 3), best first. The 12 and the 3 are a made-up
--      "average" of 4 stars counted as three reviews, so one five-star review doesn't outrank fifty good ones, and a
--      creator with no reviews yet sits level with an average one rather than at the bottom;
--   4. more reviews;
--   5. more portfolio pieces;
--   6. nearer first (a creator with no city last);
--   7. newest first, then by id, so the order never shuffles between refreshes.
--
-- The Swift side (FeaturedRules) follows the same order; SlateTests/Fixtures/featured_rules.json is checked by both.
--
-- It returns everything a tile needs in one call: the profile, the first portfolio piece's thumbnail (a path inside the
-- `portfolio` bucket), the lowest price of a published package, the review totals and the distance in kilometres from
-- the client's place (the haversine formula on a sphere of radius 6371 km, as in GeoRules). Profiles, portfolios and
-- published packages are public already; review totals come from the public creator_review_summary().
--
-- The client's place is only an argument: nothing here stores it. The app rounds it to about a kilometre first, and a
-- place that isn't a real one (or only half of one) counts as no place.

create or replace function public.featured_creators(
  p_specialty text default null,
  p_limit     integer default 12,
  p_lat       double precision default null,
  p_lon       double precision default null
)
returns table (
  id                   uuid,
  handle               text,
  display_name         text,
  bio                  text,
  specialties          text[],
  location_name        text,
  latitude             double precision,
  longitude            double precision,
  travel_radius_km     integer,
  avatar_path          text,
  created_at           timestamptz,
  updated_at           timestamptz,
  kind                 text,
  cover_path           text,
  starting_price_cents integer,
  currency_code        text,
  review_count         integer,
  rating_sum           integer,
  distance_km          double precision
)
language sql
stable
security invoker
set search_path = public
as $$
  select
    p.id, p.handle, p.display_name, p.bio, p.specialties, p.location_name, p.latitude, p.longitude,
    p.travel_radius_km, p.avatar_path, p.created_at, p.updated_at, p.kind,
    cover.thumbnail_path, price.price_cents, price.currency_code, rev.review_count, rev.rating_sum, here.distance_km
  from public.creator_profiles p
  -- A creator a client could book: this join drops everyone without a published package.
  cross join lateral (
    select k.price_cents, k.currency_code
      from public.packages k
     where k.creator_id = p.id and k.is_published
     order by k.price_cents, k.position, k.id
     limit 1
  ) price
  left join lateral (
    select i.thumbnail_path
      from public.portfolio_items i
     where i.creator_id = p.id
     order by i.position, i.created_at, i.id
     limit 1
  ) cover on true
  cross join lateral (
    select count(*)::integer as pieces from public.portfolio_items i where i.creator_id = p.id
  ) portfolio
  cross join lateral public.creator_review_summary(p.id) rev
  -- Kilometres from the client's place to the creator's city. Null unless both are real places.
  cross join lateral (
    select case
      when p_lat between -90 and 90 and p_lon between -180 and 180
       and p.latitude is not null and p.longitude is not null
      then 2 * 6371.0 * asin(least(1.0, sqrt(
             power(sin(radians(p.latitude - p_lat) / 2), 2)
             + cos(radians(p_lat)) * cos(radians(p.latitude)) * power(sin(radians(p.longitude - p_lon) / 2), 2))))
    end as distance_km
  ) here
  where p_specialty is null or p_specialty = any (p.specialties)
  order by
    coalesce(here.distance_km <= coalesce(p.travel_radius_km, 40), false) desc,
    (portfolio.pieces > 0) desc,
    (rev.rating_sum + 12.0) / (rev.review_count + 3) desc,
    rev.review_count desc,
    portfolio.pieces desc,
    here.distance_km asc nulls last,
    p.created_at desc,
    p.id
  limit least(greatest(coalesce(p_limit, 12), 1), 24);
$$;

-- Supabase gives new functions to the signed-out role too, so take it away: browsing takes an account.
revoke all on function public.featured_creators(text, integer, double precision, double precision) from public, anon;
grant execute on function public.featured_creators(text, integer, double precision, double precision) to authenticated;
