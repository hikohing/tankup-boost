-- Boost_WM: база заявок.
-- Supabase → SQL Editor → New query → вставь всё целиком.
-- ЗАМЕНИ почту в последней строке на свою (ту же, что будешь использовать для входа в заявки) → Run.

create table if not exists public.orders (
  id          bigint generated always as identity primary key,
  code        text not null check (char_length(code) <= 20),
  created_at  timestamptz not null default now(),
  status      text not null default 'new'
              check (status in ('new','accepted','in_progress','done','rejected')),
  service     text not null check (char_length(service) <= 120),
  server      text check (char_length(server) <= 40),
  nick        text not null check (char_length(nick) <= 60),
  contact     text not null check (char_length(contact) <= 120),
  details     jsonb not null default '{}'::jsonb check (pg_column_size(details) < 4000),
  comment     text check (char_length(comment) <= 1500),
  price       text check (char_length(price) <= 60),
  admin_note  text check (char_length(admin_note) <= 2000)
);

create table if not exists public.admins (
  email text primary key
);

-- Проверка «этот пользователь — админ» (видит только почту из таблицы admins).
create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.admins a
    where lower(a.email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

alter table public.orders enable row level security;
alter table public.admins enable row level security;

-- Любой посетитель может только ОТПРАВИТЬ новую заявку.
drop policy if exists "submit order" on public.orders;
create policy "submit order" on public.orders
  for insert to anon, authenticated
  with check (status = 'new' and admin_note is null);

-- Видеть и менять заявки может только админ.
drop policy if exists "admin read" on public.orders;
create policy "admin read" on public.orders
  for select to authenticated using (public.is_admin());

drop policy if exists "admin update" on public.orders;
create policy "admin update" on public.orders
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant insert on public.orders to anon, authenticated;
grant select, update on public.orders to authenticated;
revoke all on public.admins from anon, authenticated;

insert into public.admins (email) values ('ТВОЯ_ПОЧТА@example.com')
on conflict do nothing;
