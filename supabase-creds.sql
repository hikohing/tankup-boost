-- Boost_WM: данные для входа по заказу + подробности заказа в чате клиента.
-- Выполнить ОДИН раз в Supabase → SQL Editor → Run.

create table if not exists public.credentials (
  order_id    bigint primary key references public.orders(id) on delete cascade,
  login       text not null check (char_length(login) between 1 and 200),
  password    text not null check (char_length(password) between 1 and 200),
  note        text check (char_length(note) <= 500),
  updated_at  timestamptz not null default now()
);
alter table public.credentials enable row level security;

drop policy if exists "admin read creds" on public.credentials;
create policy "admin read creds" on public.credentials
  for select to authenticated using (public.is_admin());
drop policy if exists "admin delete creds" on public.credentials;
create policy "admin delete creds" on public.credentials
  for delete to authenticated using (public.is_admin());

revoke all on public.credentials from anon, authenticated;
grant select, delete on public.credentials to authenticated;

-- Клиент передаёт данные (только когда заказ принят или в работе).
create or replace function public.creds_set(p_code text, p_key text, p_login text, p_password text, p_note text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_id bigint; v_status text;
begin
  select o.id, o.status into v_id, v_status from public.orders o
   where o.code = p_code and o.secret is not null and o.secret = p_key;
  if v_id is null then raise exception 'not found'; end if;
  if v_status not in ('accepted','in_progress') then raise exception 'not allowed'; end if;
  insert into public.credentials (order_id, login, password, note, updated_at)
  values (v_id, btrim(p_login), p_password, nullif(btrim(coalesce(p_note,'')), ''), now())
  on conflict (order_id) do update
    set login = excluded.login, password = excluded.password, note = excluded.note, updated_at = now();
  insert into public.messages (order_id, author, body)
  values (v_id, 'client', '🔐 Данные для входа отправлены');
end;
$$;

-- Клиент удаляет свои данные.
create or replace function public.creds_clear(p_code text, p_key text)
returns void language plpgsql security definer set search_path = ''
as $$
declare v_id bigint;
begin
  select o.id into v_id from public.orders o
   where o.code = p_code and o.secret is not null and o.secret = p_key;
  if v_id is null then raise exception 'not found'; end if;
  delete from public.credentials where order_id = v_id;
end;
$$;

-- Данные удаляются сами, когда заказ выполнен или отклонён.
create or replace function public.creds_autowipe()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if new.status in ('done','rejected') then
    delete from public.credentials where order_id = new.id;
  end if;
  return new;
end;
$$;
drop trigger if exists orders_creds_autowipe on public.orders;
create trigger orders_creds_autowipe after update of status on public.orders
  for each row execute function public.creds_autowipe();

-- Чат клиента теперь получает и подробности заказа.
create or replace function public.chat_get(p_code text, p_key text)
returns json language sql stable security definer set search_path = ''
as $$
  select json_build_object(
    'code', o.code, 'status', o.status, 'service', o.service, 'price', o.price,
    'created_at', o.created_at, 'server', o.server, 'nick', o.nick,
    'details', o.details, 'comment', o.comment,
    'has_creds', exists (select 1 from public.credentials c where c.order_id = o.id),
    'messages', coalesce((
      select json_agg(json_build_object('id', m.id, 'author', m.author, 'body', m.body, 'at', m.created_at) order by m.id)
      from public.messages m where m.order_id = o.id
    ), '[]'::json)
  )
  from public.orders o
  where o.code = p_code and o.secret is not null and o.secret = p_key;
$$;

revoke all on function public.creds_set(text, text, text, text, text) from public;
revoke all on function public.creds_clear(text, text) from public;
revoke all on function public.creds_autowipe() from public;
grant execute on function public.creds_set(text, text, text, text, text) to anon, authenticated;
grant execute on function public.creds_clear(text, text) to anon, authenticated;
