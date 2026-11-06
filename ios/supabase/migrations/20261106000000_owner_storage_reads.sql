-- A person's own profile photo and portfolio files could not be uploaded: every attempt failed with
-- "new row violates row-level security policy".
--
-- Supabase's file service reads back the row it has just written (and always does when it replaces a file), and Postgres
-- only allows that when a read rule lets the person see the row. The `avatars` and `portfolio` buckets had rules for writing
-- but none for reading, because a public bucket can be downloaded without one. So even an upload into the person's own
-- folder was refused.
--
-- These two rules let an owner read the rows of their own folder (and a company's folder, for the people who may act for
-- that company, exactly as for writing). Nobody can read anyone else's rows, and the files themselves stay downloadable by
-- address as before. Listing a bucket's files through the API still shows an owner only their own.

create policy "Owners read their avatar files"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'avatars' and public.can_use_storage_folder((storage.foldername(name))[1]));

create policy "Owners read their portfolio files"
  on storage.objects for select
  to authenticated
  using (bucket_id = 'portfolio' and public.can_use_storage_folder((storage.foldername(name))[1]));
