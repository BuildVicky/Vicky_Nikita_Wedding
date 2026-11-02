-- =====================================================================
-- WEDDING SITE DATABASE (Supabase Free) - FINAL
-- Safe to run more than once. Contains no DROP TABLE / DELETE / TRUNCATE.
-- Run in: Supabase > SQL Editor > New query > paste all > Run.
-- Admin e-mail is set in ONE place: public.is_owner() below.
-- =====================================================================

-- Guard: stop (without changing anything) if tables from an OLDER, different script exist.
do $$
begin
  if to_regclass('public.rsvps') is not null and not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'rsvps' and column_name = 'key_hash') then
    raise exception 'An older "rsvps" table with a different layout exists. Rename it first: alter table public.rsvps rename to rsvps_old;';
  end if;
  if to_regclass('public.blessings') is not null and not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'blessings' and column_name = 'key_hash') then
    raise exception 'An older "blessings" table with a different layout exists. Rename it first: alter table public.blessings rename to blessings_old;';
  end if;
end $$;

create table if not exists public.rsvps (
  id          uuid primary key default gen_random_uuid(),
  key_hash    text not null unique,                 -- sha256 of the guest's private device key
  name        text not null check (char_length(name) between 2 and 80),
  name_norm   text generated always as (lower(regexp_replace(trim(name), '\s+', ' ', 'g'))) stored unique,
  status      text not null check (status in ('accepted','declined')),
  guests      int  not null default 0 check (guests between 0 and 20),   -- includes the guest
  message     text check (message is null or char_length(message) <= 1000),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  check ((status = 'accepted' and guests >= 1) or (status = 'declined' and guests = 0))
);

create table if not exists public.blessings (
  id           uuid primary key default gen_random_uuid(),
  key_hash     text not null,
  name         text not null check (char_length(name) between 2 and 80),
  relationship text not null check (relationship in ('Family','Friend','Relative','Couple','Colleague','Other')),
  message      text not null check (char_length(message) between 5 and 1500),
  approved     boolean not null default false,      -- PENDING until the owner approves it
  created_at   timestamptz not null default now()
);
-- Existing projects: new blessings become pending (existing rows are NOT changed).
alter table public.blessings alter column approved set default false;
create index if not exists blessings_created_idx on public.blessings (created_at desc);

-- ---- Row Level Security: visitors (anon) can touch NOTHING directly ----
alter table public.rsvps     enable row level security;
alter table public.blessings enable row level security;
grant usage on schema public to anon, authenticated;
revoke all on public.rsvps, public.blessings from anon;
grant select, insert, update, delete on public.rsvps, public.blessings to authenticated;

-- ---- Owner check (single place for the admin e-mail) ----
create or replace function public.is_owner() returns boolean
language sql stable set search_path = '' as $$
  select lower(coalesce(auth.jwt() ->> 'email', '')) = 'vicky.bhoyar11@gmail.com'
$$;
revoke all on function public.is_owner() from public, anon;
grant execute on function public.is_owner() to authenticated;

drop policy if exists "owner all rsvps" on public.rsvps;
drop policy if exists "owner all blessings" on public.blessings;
create policy "owner all rsvps" on public.rsvps for all to authenticated
  using ((select public.is_owner())) with check ((select public.is_owner()));
create policy "owner all blessings" on public.blessings for all to authenticated
  using ((select public.is_owner())) with check ((select public.is_owner()));

-- ---- Public functions (the ONLY things guests can call) ----
create or replace function public.submit_rsvp(p_name text, p_status text, p_guests int, p_message text, p_key text)
returns json language plpgsql security definer set search_path = '' as $$
declare h text; n text; m text; g int; ex public.rsvps;
begin
  if p_key is null or char_length(p_key) < 30 then raise exception 'BAD_REQUEST'; end if;
  n := trim(regexp_replace(regexp_replace(coalesce(p_name,''), '[<>]', '', 'g'), '\s+', ' ', 'g'));
  if char_length(n) not between 2 and 80 then raise exception 'BAD_NAME'; end if;
  if p_status is null or p_status not in ('accepted','declined') then raise exception 'BAD_STATUS'; end if;
  if p_status = 'accepted' then
    g := p_guests; if g is null or g < 1 or g > 20 then raise exception 'BAD_GUESTS'; end if;
  else g := 0; end if;
  m := nullif(trim(regexp_replace(regexp_replace(coalesce(p_message,''), '[<>]', '', 'g'), '[\x01-\x08\x0B\x0C\x0E-\x1F]', '', 'g')), '');
  if m is not null and char_length(m) > 1000 then raise exception 'BAD_MESSAGE'; end if;
  h := encode(sha256(convert_to(p_key, 'utf8')), 'hex');
  select * into ex from public.rsvps where key_hash = h;
  if found then   -- same device updating its own RSVP: update, never duplicate
    if exists (select 1 from public.rsvps where name_norm = lower(n) and id <> ex.id) then raise exception 'NAME_TAKEN'; end if;
    update public.rsvps set name = n, status = p_status, guests = g, message = m, updated_at = now() where id = ex.id;
    return json_build_object('ok', true, 'updated', true);
  end if;
  if exists (select 1 from public.rsvps where name_norm = lower(n)) then raise exception 'NAME_TAKEN'; end if;
  if (select count(*) from public.rsvps where created_at > now() - interval '10 minutes') > 40 then raise exception 'TOO_MANY'; end if;
  insert into public.rsvps (key_hash, name, status, guests, message) values (h, n, p_status, g, m);
  return json_build_object('ok', true, 'updated', false);
exception when unique_violation then
  raise exception 'NAME_TAKEN';
end $$;

create or replace function public.my_rsvp(p_key text)
returns json language sql security definer set search_path = '' as $$
  select row_to_json(t) from (select name, status, guests, message from public.rsvps
    where key_hash = encode(sha256(convert_to(p_key, 'utf8')), 'hex')) t;
$$;

create or replace function public.guest_wall()   -- public: names + attendee total of ACCEPTED replies only
returns json language sql security definer set search_path = '' as $$
  select json_build_object(
    'total', coalesce(sum(guests), 0),
    'guests', coalesce(json_agg(json_build_object('name', name, 'guests', guests) order by created_at), '[]'::json))
  from public.rsvps where status = 'accepted';
$$;

create or replace function public.submit_blessing(p_name text, p_rel text, p_msg text, p_key text)
returns json language plpgsql security definer set search_path = '' as $$
declare h text; n text; m text;
begin
  if p_key is null or char_length(p_key) < 30 then raise exception 'BAD_REQUEST'; end if;
  n := trim(regexp_replace(regexp_replace(coalesce(p_name,''), '[<>]', '', 'g'), '\s+', ' ', 'g'));
  m := trim(regexp_replace(regexp_replace(coalesce(p_msg,''), '[<>]', '', 'g'), '[\x01-\x08\x0B\x0C\x0E-\x1F]', '', 'g'));
  if char_length(n) not between 2 and 80 then raise exception 'BAD_NAME'; end if;
  if p_rel is null or p_rel not in ('Family','Friend','Relative','Couple','Colleague','Other') then raise exception 'BAD_REL'; end if;
  if char_length(m) not between 5 and 1500 then raise exception 'BAD_MESSAGE'; end if;
  h := encode(sha256(convert_to(p_key, 'utf8')), 'hex');
  if (select count(*) from public.blessings where key_hash = h and created_at > now() - interval '1 hour') >= 3 then raise exception 'TOO_MANY'; end if;
  if (select count(*) from public.blessings where created_at > now() - interval '10 minutes') > 60 then raise exception 'TOO_MANY'; end if;
  insert into public.blessings (key_hash, name, relationship, message, approved) values (h, n, p_rel, m, false);
  return json_build_object('ok', true);
end $$;

create or replace function public.list_blessings()   -- public: APPROVED only, no private fields
returns json language sql security definer set search_path = '' as $$
  select coalesce(json_agg(t), '[]'::json) from (
    select name, relationship, message, created_at from public.blessings
    where approved order by created_at desc limit 300) t;
$$;

revoke all on function public.submit_rsvp(text,text,int,text,text), public.my_rsvp(text), public.guest_wall(),
  public.submit_blessing(text,text,text,text), public.list_blessings() from public;
grant execute on function public.submit_rsvp(text,text,int,text,text), public.my_rsvp(text), public.guest_wall(),
  public.submit_blessing(text,text,text,text), public.list_blessings() to anon, authenticated;
