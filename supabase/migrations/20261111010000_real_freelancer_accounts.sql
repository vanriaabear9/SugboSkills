-- Apply after schema.sql and prototype-marketplace.sql.
alter table public.profiles
  add column if not exists username text,
  add column if not exists freelancer_id text references public.prototype_freelancers (id) on delete set null;

with named_profiles as (
  select
    id,
    coalesce(nullif(btrim(full_name), ''), split_part(email, '@', 1)) as candidate,
    row_number() over (
      partition by lower(coalesce(nullif(btrim(full_name), ''), split_part(email, '@', 1)))
      order by created_at, id
    ) as duplicate_number
  from public.profiles
  where username is null
)
update public.profiles p
set username = case
  when named_profiles.duplicate_number = 1 then named_profiles.candidate
  else named_profiles.candidate || '-' || left(named_profiles.id::text, 6)
end
from named_profiles
where p.id = named_profiles.id;

create unique index if not exists profiles_username_ci_unique
  on public.profiles (lower(username));

create unique index if not exists profiles_freelancer_id_unique
  on public.profiles (freelancer_id)
  where freelancer_id is not null;

alter table public.profiles
  alter column username set not null;

create or replace function public.create_client_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, full_name, business_name, email, username, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data ->> 'full_name', ''),
    new.raw_user_meta_data ->> 'business_name',
    new.email,
    coalesce(
      nullif(btrim(new.raw_user_meta_data ->> 'username'), ''),
      split_part(new.email, '@', 1)
    ),
    'client'
  )
  on conflict (id) do nothing;
  return new;
end;
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
      or new.username is distinct from old.username
      or new.freelancer_id is distinct from old.freelancer_id
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

create or replace function public.is_active_freelancer()
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
      and role = 'freelancer'
      and status = 'active'
      and freelancer_id is not null
  );
$$;

drop function if exists public.get_prototype_freelancer_bookings(text);
drop function if exists public.get_prototype_freelancer_bookings();

create function public.get_prototype_freelancer_bookings()
returns table (
  id uuid,
  reference text,
  client_name text,
  client_business text,
  freelancer_id text,
  title text,
  description text,
  requirements text,
  skill text,
  level text,
  booking_date date,
  deadline date,
  budget integer,
  status text,
  project_status text,
  created_at timestamptz
)
language sql
stable
security definer
set search_path = public
set row_security = off
as $$
  select b.id, b.reference, b.client_name, b.client_business,
         b.freelancer_id, b.title, b.description,
         b.requirements, b.skill, b.level, b.booking_date, b.deadline,
         b.budget, b.status, b.project_status, b.created_at
  from public.prototype_bookings b
  join public.profiles p
    on p.freelancer_id = b.freelancer_id
   and p.id = auth.uid()
   and p.role = 'freelancer'
   and p.status = 'active'
  order by b.created_at desc;
$$;

drop function if exists public.respond_to_prototype_booking(uuid, text, text);
drop function if exists public.respond_to_prototype_booking(uuid, text);

create function public.respond_to_prototype_booking(
  p_booking_id uuid,
  p_response text
)
returns boolean
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  updated_count integer;
begin
  if not public.is_active_freelancer() then
    raise exception 'An active freelancer account is required.';
  end if;
  if p_response is null or p_response not in ('accept', 'decline') then
    raise exception 'Response must be accept or decline.';
  end if;

  update public.prototype_bookings b
  set status = case when p_response = 'accept' then 'Confirmed' else 'Declined' end,
      project_status = case when p_response = 'accept' then 'Upcoming' else 'Cancelled' end
  where b.id = p_booking_id
    and b.status = 'Pending'
    and exists (
      select 1
      from public.profiles p
      where p.id = auth.uid()
        and p.role = 'freelancer'
        and p.status = 'active'
        and p.freelancer_id = b.freelancer_id
    );

  get diagnostics updated_count = row_count;
  return updated_count = 1;
end;
$$;

drop function if exists public.update_prototype_booking_progress(uuid, text, text);
drop function if exists public.update_prototype_booking_progress(uuid, text);

create function public.update_prototype_booking_progress(
  p_booking_id uuid,
  p_project_status text
)
returns boolean
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  updated_count integer;
begin
  if not public.is_active_freelancer() then
    raise exception 'An active freelancer account is required.';
  end if;
  if p_project_status is null or p_project_status not in ('Upcoming', 'In Progress', 'Submitted for Review', 'Completed') then
    raise exception 'Invalid project status.';
  end if;

  update public.prototype_bookings b
  set project_status = p_project_status,
      status = case when p_project_status = 'Completed' then 'Completed' else 'Confirmed' end
  where b.id = p_booking_id
    and b.status = 'Confirmed'
    and exists (
      select 1
      from public.profiles p
      where p.id = auth.uid()
        and p.role = 'freelancer'
        and p.status = 'active'
        and p.freelancer_id = b.freelancer_id
    );

  get diagnostics updated_count = row_count;
  return updated_count = 1;
end;
$$;

revoke all on function public.get_prototype_freelancer_bookings() from public, anon;
revoke all on function public.respond_to_prototype_booking(uuid, text) from public, anon;
revoke all on function public.update_prototype_booking_progress(uuid, text) from public, anon;
revoke all on function public.is_active_freelancer() from public, anon;
grant execute on function public.is_active_freelancer() to authenticated;
grant execute on function public.get_prototype_freelancer_bookings() to authenticated;
grant execute on function public.respond_to_prototype_booking(uuid, text) to authenticated;
grant execute on function public.update_prototype_booking_progress(uuid, text) to authenticated;

notify pgrst, 'reload schema';
