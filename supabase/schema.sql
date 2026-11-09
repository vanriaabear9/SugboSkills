create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  full_name text not null default '',
  business_name text,
  email text not null unique,
  role text not null default 'client' check (role in ('client', 'admin', 'freelancer')),
  skill text,
  level text check (level in ('intermediate', 'advanced')),
  team text check (team in ('A', 'B')),
  status text not null default 'active' check (status in ('active', 'inactive')),
  created_at timestamptz not null default now()
);

create or replace function public.create_client_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, business_name, email, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    new.raw_user_meta_data ->> 'business_name',
    new.email,
    'client'
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists create_profile_after_signup on auth.users;
create trigger create_profile_after_signup
after insert on auth.users
for each row execute function public.create_client_profile();

create or replace function public.is_active_admin()
returns boolean
language sql
stable
security definer
set search_path = public
set row_security = off
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and role = 'admin'
      and status = 'active'
  );
$$;

create or replace function public.protect_profile_fields()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null
    and auth.uid() = old.id
    and not public.is_active_admin()
    and (
      new.id is distinct from old.id
      or new.email is distinct from old.email
      or new.role is distinct from old.role
      or new.skill is distinct from old.skill
      or new.level is distinct from old.level
      or new.team is distinct from old.team
      or new.status is distinct from old.status
      or new.created_at is distinct from old.created_at
    )
  then
    raise exception 'You may only update your name and business name.';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_profile_fields_before_update on public.profiles;
create trigger protect_profile_fields_before_update
before update on public.profiles
for each row execute function public.protect_profile_fields();

alter table public.profiles enable row level security;

drop policy if exists "Users read own profile" on public.profiles;
create policy "Users read own profile"
on public.profiles for select
to authenticated
using (id = auth.uid());

drop policy if exists "Admins read all profiles" on public.profiles;
create policy "Admins read all profiles"
on public.profiles for select
to authenticated
using (public.is_active_admin());

drop policy if exists "Users update own profile" on public.profiles;
create policy "Users update own profile"
on public.profiles for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid());

drop policy if exists "Admins manage all profiles" on public.profiles;
create policy "Admins manage all profiles"
on public.profiles for all
to authenticated
using (public.is_active_admin())
with check (public.is_active_admin());

grant select, insert, delete on public.profiles to authenticated;
grant update (full_name, business_name, email, role, skill, level, team, status, created_at)
  on public.profiles to authenticated;
grant execute on function public.is_active_admin() to authenticated;

-- After creating vanriaabear9@gmail.com in Authentication > Users, run this once:
-- update public.profiles
-- set role = 'admin'
-- where lower(email) = lower('vanriaabear9@gmail.com');
