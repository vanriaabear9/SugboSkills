drop function if exists public.get_prototype_freelancer_bookings(text);

create function public.get_prototype_freelancer_bookings(p_freelancer_id text)
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
  where b.freelancer_id = p_freelancer_id
  order by b.created_at desc;
$$;

grant execute on function public.get_prototype_freelancer_bookings(text) to anon, authenticated;

notify pgrst, 'reload schema';
