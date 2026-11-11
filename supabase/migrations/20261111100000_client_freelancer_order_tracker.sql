alter table public.prototype_bookings
  add column if not exists payment_status text not null default 'Unpaid',
  add column if not exists payment_released_at timestamptz;

alter table public.prototype_bookings
  drop constraint if exists prototype_bookings_project_status_check;

alter table public.prototype_bookings
  add constraint prototype_bookings_project_status_check
  check (project_status in (
    'Upcoming',
    'In Progress',
    'Submitted for Review',
    'Submitted',
    'Completed',
    'Cancelled'
  ));

alter table public.prototype_bookings
  add constraint prototype_bookings_payment_status_check
  check (payment_status in ('Unpaid', 'Held (Test)', 'Released (Test)'));

create table if not exists public.prototype_booking_messages (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.prototype_bookings (id) on delete cascade,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index if not exists prototype_booking_messages_order
  on public.prototype_booking_messages (booking_id, created_at);

alter table public.prototype_booking_messages enable row level security;

create or replace function public.is_prototype_booking_participant(p_booking_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
set row_security = off
as $$
  select exists (
    select 1
    from public.prototype_bookings b
    where b.id = p_booking_id
      and b.status not in ('Cancelled', 'Declined')
      and (
        b.client_id = auth.uid()
        or exists (
          select 1
          from public.profiles p
          where p.id = auth.uid()
            and p.role = 'freelancer'
            and p.status = 'active'
            and p.freelancer_id = b.freelancer_id
        )
      )
  );
$$;

drop policy if exists "Booking participants read messages" on public.prototype_booking_messages;
create policy "Booking participants read messages"
on public.prototype_booking_messages for select
to authenticated
using (public.is_prototype_booking_participant(booking_id));

drop policy if exists "Booking participants send messages" on public.prototype_booking_messages;
create policy "Booking participants send messages"
on public.prototype_booking_messages for insert
to authenticated
with check (
  sender_id = auth.uid()
  and public.is_prototype_booking_participant(booking_id)
);

grant select, insert on public.prototype_booking_messages to authenticated;
revoke update, delete on public.prototype_booking_messages from authenticated;
revoke all on function public.is_prototype_booking_participant(uuid) from public, anon;
grant execute on function public.is_prototype_booking_participant(uuid) to authenticated;

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
  payment_status text,
  payment_released_at timestamptz,
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
         b.budget, b.status, b.project_status, b.payment_status,
         b.payment_released_at, b.created_at
  from public.prototype_bookings b
  join public.profiles p
    on p.freelancer_id = b.freelancer_id
   and p.id = auth.uid()
   and p.role = 'freelancer'
   and p.status = 'active'
  order by b.created_at desc;
$$;

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
      project_status = case when p_response = 'accept' then 'In Progress' else 'Cancelled' end
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
  if p_project_status is null or p_project_status not in (
    'In Progress',
    'Submitted for Review',
    'Submitted'
  ) then
    raise exception 'Invalid project status.';
  end if;

  update public.prototype_bookings b
  set project_status = p_project_status
  where b.id = p_booking_id
    and b.status = 'Confirmed'
    and (
      (b.project_status = 'In Progress' and p_project_status in ('In Progress', 'Submitted for Review'))
      or (b.project_status = 'Submitted for Review' and p_project_status in ('Submitted for Review', 'Submitted'))
      or (b.project_status = 'Submitted' and p_project_status = 'Submitted')
    )
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

create or replace function public.fund_prototype_booking_escrow(p_booking_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  updated_count integer;
begin
  if not public.is_active_client() then
    raise exception 'An active client account is required.';
  end if;

  update public.prototype_bookings
  set payment_status = 'Held (Test)'
  where id = p_booking_id
    and client_id = auth.uid()
    and status = 'Confirmed'
    and payment_status = 'Unpaid';

  get diagnostics updated_count = row_count;
  return updated_count = 1;
end;
$$;

create or replace function public.approve_prototype_booking_delivery(p_booking_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
set row_security = off
as $$
declare
  updated_count integer;
begin
  if not public.is_active_client() then
    raise exception 'An active client account is required.';
  end if;

  update public.prototype_bookings
  set payment_status = 'Released (Test)',
      payment_released_at = now(),
      project_status = 'Completed',
      status = 'Completed'
  where id = p_booking_id
    and client_id = auth.uid()
    and status = 'Confirmed'
    and project_status = 'Submitted'
    and payment_status = 'Held (Test)';

  get diagnostics updated_count = row_count;
  return updated_count = 1;
end;
$$;

create or replace function public.get_prototype_freelancer_portfolio(p_freelancer_id text)
returns table (
  booking_id uuid,
  title text,
  description text,
  skill text,
  payment_released_at timestamptz
)
language sql
stable
security definer
set search_path = public
set row_security = off
as $$
  select b.id, b.title, b.description, b.skill, b.payment_released_at
  from public.prototype_bookings b
  where b.freelancer_id = p_freelancer_id
    and b.payment_status = 'Released (Test)'
  order by b.payment_released_at desc;
$$;

revoke all on function public.get_prototype_freelancer_bookings() from public, anon;
revoke all on function public.respond_to_prototype_booking(uuid, text) from public, anon;
revoke all on function public.update_prototype_booking_progress(uuid, text) from public, anon;
revoke all on function public.fund_prototype_booking_escrow(uuid) from public, anon;
revoke all on function public.approve_prototype_booking_delivery(uuid) from public, anon;
revoke all on function public.get_prototype_freelancer_portfolio(text) from public;

grant execute on function public.get_prototype_freelancer_bookings() to authenticated;
grant execute on function public.respond_to_prototype_booking(uuid, text) to authenticated;
grant execute on function public.update_prototype_booking_progress(uuid, text) to authenticated;
grant execute on function public.fund_prototype_booking_escrow(uuid) to authenticated;
grant execute on function public.approve_prototype_booking_delivery(uuid) to authenticated;
grant execute on function public.get_prototype_freelancer_portfolio(text) to anon, authenticated;

notify pgrst, 'reload schema';
