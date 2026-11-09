-- Somente para teste local fora do Supabase: simula roles/schemas que o Supabase já fornece.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema auth; create schema extensions;
create table auth.users (id uuid primary key, instance_id uuid, aud text, role text, email text, encrypted_password text, created_at timestamptz, updated_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claims', true)::jsonb->>'sub','')::uuid $$;
grant usage on schema auth, extensions to authenticated, service_role, anon;
grant usage on schema public to anon, authenticated, service_role;
grant execute on function auth.uid() to authenticated, service_role, anon;
