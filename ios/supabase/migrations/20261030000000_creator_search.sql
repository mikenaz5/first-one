-- Find a creator to book, by name, link name or specialty. The client's Creators tab uses it.
--
-- Only creators a client could actually book are found: those with at least one published package. Profiles are
-- public already (anyone with a link can read a page), so this adds no exposure; it only saves the app from asking
-- for every profile and filtering on the phone.

-- A search word with LIKE's own characters made plain, so "50%" or "a_b" means those characters.
create or replace function public.like_escape(p_text text)
returns text
language sql
immutable
set search_path = public
as $$
  select replace(replace(replace(coalesce(p_text, ''), '\', '\\'), '%', '\%'), '_', '\_');
$$;

create or replace function public.search_creators(p_query text, p_limit integer default 20)
returns setof public.creator_profiles
language sql
stable
security invoker
set search_path = public
as $$
  with q as (
    select
      -- Case and spacing don't matter: "Real Estate" finds the realEstate specialty.
      lower(regexp_replace(btrim(coalesce(p_query, '')), '\s+', ' ', 'g')) as spaced,
      lower(regexp_replace(btrim(coalesce(p_query, '')), '\s+', '',  'g')) as squeezed
  )
  select p.*
  from public.creator_profiles p, q
  where char_length(q.squeezed) between 2 and 60
    and exists (select 1 from public.packages k where k.creator_id = p.id and k.is_published)
    and (
         lower(p.display_name) like '%' || public.like_escape(q.spaced) || '%' escape '\'
      or p.handle like '%' || public.like_escape(q.squeezed) || '%' escape '\'
      or exists (
           select 1 from unnest(p.specialties) s
           where lower(s) like '%' || public.like_escape(q.squeezed) || '%' escape '\'
         )
    )
  order by
    -- The creator whose link name is exactly this, then names that start with it, then the rest.
    (p.handle = q.squeezed) desc,
    (lower(p.display_name) like public.like_escape(q.spaced) || '%' escape '\') desc,
    p.display_name
  limit least(greatest(coalesce(p_limit, 20), 1), 30);
$$;

-- Supabase gives new functions to the signed-out role too, so take it away: searching takes an account.
revoke all on function public.like_escape(text) from public, anon;
revoke all on function public.search_creators(text, integer) from public, anon;
grant execute on function public.search_creators(text, integer) to authenticated;
grant execute on function public.like_escape(text) to authenticated;
