create table if not exists public.prototype_booking_review_messages (
  id uuid primary key default gen_random_uuid(),
  booking_id uuid not null references public.prototype_bookings (id) on delete cascade,
  sender_id uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 2000),
  created_at timestamptz not null default now()
);

create index if not exists prototype_booking_review_messages_order
  on public.prototype_booking_review_messages (booking_id, created_at);

alter table public.prototype_booking_review_messages enable row level security;

create or replace function public.is_prototype_booking_review_participant(p_booking_id uuid)
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
    join public.profiles p
      on p.id = auth.uid()
     and p.status = 'active'
    where b.id = p_booking_id
      and b.status in ('Confirmed', 'Completed')
      and (
        p.role = 'admin'
        or (p.role = 'freelancer' and p.freelancer_id = b.freelancer_id)
      )
  );
$$;

drop policy if exists "Review participants read company messages"
  on public.prototype_booking_review_messages;
create policy "Review participants read company messages"
on public.prototype_booking_review_messages for select
to authenticated
using (public.is_prototype_booking_review_participant(booking_id));

drop policy if exists "Review participants send company messages"
  on public.prototype_booking_review_messages;
create policy "Review participants send company messages"
on public.prototype_booking_review_messages for insert
to authenticated
with check (
  sender_id = auth.uid()
  and public.is_prototype_booking_review_participant(booking_id)
);

grant select, insert on public.prototype_booking_review_messages to authenticated;
revoke update, delete on public.prototype_booking_review_messages from authenticated;
revoke all on function public.is_prototype_booking_review_participant(uuid) from public, anon;
grant execute on function public.is_prototype_booking_review_participant(uuid) to authenticated;
