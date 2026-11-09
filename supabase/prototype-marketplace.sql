-- Passwordless freelancer prototype roster and shared client booking requests.
-- Run after schema.sql. Prototype freelancers are roster records, not Auth users.

create table if not exists public.prototype_freelancers (
  id text primary key,
  sort_order integer not null unique,
  name text not null,
  skill text not null check (skill in (
    'Graphic Design',
    'Video Editing',
    'Photo Editing',
    'Web Design and Development',
    'CAD and 3d Modelling'
  )),
  level text not null check (level in ('Intermediate', 'Advanced')),
  status text not null default 'Active' check (status in ('Active', 'Inactive')),
  rating numeric(2, 1) not null default 4.8 check (rating between 0 and 5),
  reviews integer not null default 0 check (reviews >= 0),
  created_at timestamptz not null default now()
);

insert into public.prototype_freelancers (id, sort_order, name, skill, level) values
  ('roster-barbie-igot', 1, 'Barbie Igot', 'Graphic Design', 'Advanced'),
  ('roster-cryzza-belotindos', 2, 'Cryzza Belotindos', 'Graphic Design', 'Advanced'),
  ('roster-valir-dela-cruz', 3, 'Valir Dela Cruz', 'Graphic Design', 'Intermediate'),
  ('roster-joshua-reyes', 4, 'Joshua Reyes', 'Graphic Design', 'Intermediate'),
  ('roster-dane-aying', 5, 'Dane Aying', 'Video Editing', 'Advanced'),
  ('roster-romel-namocatcat', 6, 'Romel Namocatcat', 'Video Editing', 'Advanced'),
  ('roster-shaina-chua', 7, 'Shaina Chua', 'Video Editing', 'Intermediate'),
  ('roster-meghan-red', 8, 'Meghan Red', 'Video Editing', 'Intermediate'),
  ('roster-archiel-gilhang', 9, 'Archiel Gilhang', 'Photo Editing', 'Advanced'),
  ('roster-daniel-rosialda', 10, 'Daniel Rosialda', 'Photo Editing', 'Advanced'),
  ('roster-thompson-flores', 11, 'Thompson Flores', 'Photo Editing', 'Intermediate'),
  ('roster-rey-garcia', 12, 'Rey Garcia', 'Photo Editing', 'Intermediate'),
  ('roster-vincent-augusto', 13, 'Vincent Augusto', 'Web Design and Development', 'Advanced'),
  ('roster-michael-tagaan', 14, 'Michael Tagaan', 'Web Design and Development', 'Advanced'),
  ('roster-lester-lumactud', 15, 'Lester Lumactud', 'Web Design and Development', 'Intermediate'),
  ('roster-kyr-nadela', 16, 'Kyr Nadela', 'Web Design and Development', 'Intermediate'),
  ('roster-mikae-molina', 17, 'Mikae Molina', 'CAD and 3d Modelling', 'Advanced'),
  ('roster-justin-aldevera', 18, 'Justin Aldevera', 'CAD and 3d Modelling', 'Advanced'),
  ('roster-mariah-cassandra', 19, 'Mariah Cassandra', 'CAD and 3d Modelling', 'Intermediate'),
  ('roster-peter-aquino', 20, 'Peter Aquino', 'CAD and 3d Modelling', 'Intermediate'),
  ('alex-rivera', 21, 'Alex Rivera', 'Graphic Design', 'Intermediate'),
  ('john-perez', 22, 'John Perez', 'Video Editing', 'Intermediate')
on conflict (id) do nothing;

create table if not exists public.prototype_bookings (
  id uuid primary key default gen_random_uuid(),
  reference text not null unique default ('SS-' || upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8))),
  client_id uuid not null references public.profiles (id) on delete cascade,
  client_name text not null,
  client_business text not null,
  freelancer_id text not null references public.prototype_freelancers (id),
  title text not null check (char_length(title) between 1 and 100),
  description text not null check (char_length(description) between 1 and 1200),
  requirements text not null check (char_length(requirements) between 1 and 800),
  skill text not null,
  level text not null check (level in ('Intermediate', 'Advanced')),
  booking_date date not null,
  deadline date not null,
  budget integer not null check (budget between 500 and 3000),
  status text not null default 'Pending' check (status in ('Pending', 'Confirmed', 'Declined', 'Cancelled', 'Completed')),
  project_status text not null default 'Upcoming' check (project_status in ('Upcoming', 'In Progress', 'Submitted for Review', 'Completed', 'Cancelled')),
  created_at timestamptz not null default now(),
  check (deadline >= booking_date),
  check (
    (level = 'Intermediate' and budget between 500 and 1000)
    or (level = 'Advanced' and budget between 1500 and 3000)
  )
);

create unique index if not exists prototype_bookings_one_open_slot
  on public.prototype_bookings (booking_date, freelancer_id)
  where status in ('Pending', 'Confirmed');

create or replace function public.is_active_client()
returns boolean
language sql
stable
security definer
set search_path = public
set row_security = off
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'client' and status = 'active'
  );
$$;

alter table public.prototype_freelancers enable row level security;
alter table public.prototype_bookings enable row level security;

create policy "Anyone reads active prototype freelancers"
on public.prototype_freelancers for select
to anon, authenticated
using (status = 'Active' or public.is_active_admin());

create policy "Admins manage prototype freelancers"
on public.prototype_freelancers for all
to authenticated
using (public.is_active_admin())
with check (public.is_active_admin());

create policy "Clients read their own prototype bookings"
on public.prototype_bookings for select
to authenticated
using (client_id = auth.uid() or public.is_active_admin());

create policy "Active clients create their own prototype bookings"
on public.prototype_bookings for insert
to authenticated
with check (
  client_id = auth.uid()
  and public.is_active_client()
  and status = 'Pending'
  and project_status = 'Upcoming'
  and booking_date >= current_date
  and exists (
    select 1 from public.prototype_freelancers f
    where f.id = prototype_bookings.freelancer_id
      and f.status = 'Active'
      and f.skill = prototype_bookings.skill
      and f.level = prototype_bookings.level
  )
);

create policy "Admins manage prototype bookings"
on public.prototype_bookings for all
to authenticated
using (public.is_active_admin())
with check (public.is_active_admin());

grant select on public.prototype_freelancers to anon, authenticated;
grant insert, select, update, delete on public.prototype_bookings to authenticated;

create or replace function public.get_prototype_booked_slots()
returns table (booking_id uuid, freelancer_id text, skill text, booking_date date)
language sql
stable
security definer
set search_path = public
set row_security = off
as $$
  select b.id, b.freelancer_id, b.skill, b.booking_date
  from public.prototype_bookings b
  where b.status in ('Pending', 'Confirmed');
$$;

create or replace function public.get_prototype_freelancer_bookings(p_freelancer_id text)
returns table (
  id uuid,
  reference text,
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
  select b.id, b.reference, b.freelancer_id, b.title, b.description,
         b.requirements, b.skill, b.level, b.booking_date, b.deadline,
         b.budget, b.status, b.project_status, b.created_at
  from public.prototype_bookings b
  where b.freelancer_id = p_freelancer_id
  order by b.created_at desc;
$$;

create or replace function public.respond_to_prototype_booking(
  p_booking_id uuid,
  p_freelancer_id text,
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
  if p_response is null or p_response not in ('accept', 'decline') then
    raise exception 'Response must be accept or decline.';
  end if;

  update public.prototype_bookings
  set status = case when p_response = 'accept' then 'Confirmed' else 'Declined' end,
      project_status = case when p_response = 'accept' then 'Upcoming' else 'Cancelled' end
  where id = p_booking_id
    and freelancer_id = p_freelancer_id
    and status = 'Pending';

  get diagnostics updated_count = row_count;
  return updated_count = 1;
end;
$$;

create or replace function public.update_prototype_booking_progress(
  p_booking_id uuid,
  p_freelancer_id text,
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
  if p_project_status is null or p_project_status not in ('Upcoming', 'In Progress', 'Submitted for Review', 'Completed') then
    raise exception 'Invalid project status.';
  end if;

  update public.prototype_bookings
  set project_status = p_project_status,
      status = case when p_project_status = 'Completed' then 'Completed' else 'Confirmed' end
  where id = p_booking_id
    and freelancer_id = p_freelancer_id
    and status = 'Confirmed';

  get diagnostics updated_count = row_count;
  return updated_count = 1;
end;
$$;

create or replace function public.cancel_prototype_booking(p_booking_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  updated_count integer;
begin
  update public.prototype_bookings
  set status = 'Cancelled', project_status = 'Cancelled'
  where id = p_booking_id
    and client_id = auth.uid()
    and status = 'Pending';

  get diagnostics updated_count = row_count;
  return updated_count = 1;
end;
$$;

grant execute on function public.is_active_client() to authenticated;
grant execute on function public.get_prototype_booked_slots() to anon, authenticated;
grant execute on function public.get_prototype_freelancer_bookings(text) to anon, authenticated;
grant execute on function public.respond_to_prototype_booking(uuid, text, text) to anon, authenticated;
grant execute on function public.update_prototype_booking_progress(uuid, text, text) to anon, authenticated;
grant execute on function public.cancel_prototype_booking(uuid) to authenticated;
