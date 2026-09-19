-- Boost_WM: чат по заявке. Выполнить ОДИН раз в Supabase → SQL Editor → Run.

-- Секретный ключ заявки: по нему клиент открывает свой чат.
alter table public.orders add column if not exists secret text
  check (secret is null or char_length(secret) between 24 and 64);

create table if not exists public.messages (
  id          bigint generated always as identity primary key,
  order_id    bigint not null references public.orders(id) on delete cascade,
  author      text not null check (author in ('client','admin')),
  body        text not null check (char_length(body) between 1 and 2000),
  created_at  timestamptz not null default now(),
  seen        boolean not null default false
);
create index if not exists messages_order_idx on public.messages (order_id, id);

alter table public.messages enable row level security;

drop policy if exists "admin read messages" on public.messages;
create policy "admin read messages" on public.messages
  for select to authenticated using (public.is_admin());

drop policy if exists "admin write messages" on public.messages;
create policy "admin write messages" on public.messages
  for insert to authenticated with check (public.is_admin() and author = 'admin');

drop policy if exists "admin update messages" on public.messages;
create policy "admin update messages" on public.messages
  for update to authenticated using (public.is_admin()) with check (public.is_admin());

grant select, insert, update on public.messages to authenticated;

-- Клиент читает свой чат (только зная номер заявки И секретный ключ).
create or replace function public.chat_get(p_code text, p_key text)
returns json
language sql
stable
security definer
set search_path = ''
as $$
  select json_build_object(
    'code', o.code, 'status', o.status, 'service', o.service,
    'price', o.price, 'created_at', o.created_at,
    'messages', coalesce((
      select json_agg(json_build_object('id', m.id, 'author', m.author, 'body', m.body, 'at', m.created_at) order by m.id)
      from public.messages m where m.order_id = o.id
    ), '[]'::json)
  )
  from public.orders o
  where o.code = p_code and o.secret is not null and o.secret = p_key;
$$;

-- Клиент пишет в свой чат (не больше 10 сообщений в минуту).
create or replace function public.chat_send(p_code text, p_key text, p_body text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id   bigint;
  v_body text := btrim(coalesce(p_body, ''));
begin
  if char_length(v_body) = 0 or char_length(v_body) > 2000 then
    raise exception 'bad message';
  end if;
  select o.id into v_id from public.orders o
   where o.code = p_code and o.secret is not null and o.secret = p_key;
  if v_id is null then
    raise exception 'not found';
  end if;
  if (select count(*) from public.messages m
       where m.order_id = v_id and m.author = 'client'
         and m.created_at > now() - interval '1 minute') >= 10 then
    raise exception 'too many messages';
  end if;
  insert into public.messages (order_id, author, body) values (v_id, 'client', v_body);
end;
$$;

revoke all on function public.chat_get(text, text) from public;
revoke all on function public.chat_send(text, text, text) from public;
grant execute on function public.chat_get(text, text) to anon, authenticated;
grant execute on function public.chat_send(text, text, text) to anon, authenticated;
