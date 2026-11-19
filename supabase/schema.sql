-- ENFapp: esquema do banco (Supabase). Rode no SQL Editor de um projeto novo.
create table if not exists public.app_data (
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  key text not null, value jsonb, updated_at timestamptz default now(),
  primary key (user_id, key));
alter table public.app_data enable row level security;
create policy "dono le" on public.app_data for select using (auth.uid() = user_id);
create policy "dono insere" on public.app_data for insert with check (auth.uid() = user_id);
create policy "dono atualiza" on public.app_data for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
create policy "dono apaga" on public.app_data for delete using (auth.uid() = user_id);
alter publication supabase_realtime add table public.app_data;

-- Arquivos (pastas por usuario: <uid>/documentos, assinaturas, produtividade)
insert into storage.buckets (id, name, public, file_size_limit) values ('enfapp','enfapp',false,10485760) on conflict (id) do nothing;
create policy "enfapp le" on storage.objects for select to authenticated using (bucket_id='enfapp' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "enfapp envia" on storage.objects for insert to authenticated with check (bucket_id='enfapp' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "enfapp atualiza" on storage.objects for update to authenticated using (bucket_id='enfapp' and (storage.foldername(name))[1]=auth.uid()::text);
create policy "enfapp apaga" on storage.objects for delete to authenticated using (bucket_id='enfapp' and (storage.foldername(name))[1]=auth.uid()::text);

-- Perfis, planos e conta master (troque o e-mail master abaixo)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text, nome text, avatar text,
  plan text not null default 'basico' check (plan in ('basico','profissional','premium')),
  role text not null default 'user' check (role in ('user','master')),
  created_at timestamptz default now());
alter table public.profiles enable row level security;
create or replace function public.is_master() returns boolean language sql stable security definer set search_path=public as
$$ select exists (select 1 from public.profiles where id = auth.uid() and role = 'master') $$;
revoke execute on function public.is_master() from public, anon;
grant execute on function public.is_master() to authenticated;
create policy "perfil le" on public.profiles for select to authenticated using (id = auth.uid() or public.is_master());
create policy "perfil atualiza" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from authenticated, anon;
grant update (nome, avatar) on public.profiles to authenticated;
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare m boolean := lower(new.email) = 'gmdesignferoz@gmail.com';
begin
  insert into public.profiles (id,email,nome,role,plan)
  values (new.id,new.email,coalesce(new.raw_user_meta_data->>'nome',new.raw_user_meta_data->>'full_name',split_part(new.email,'@',1)),
    case when m then 'master' else 'user' end, case when m then 'premium' else 'basico' end)
  on conflict (id) do nothing;
  return new;
end $$;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();
create or replace function public.set_plan(p_id uuid, p_plan text) returns void language plpgsql security definer set search_path=public as $$
begin
  if not public.is_master() then raise exception 'sem permissao'; end if;
  if p_plan not in ('basico','profissional','premium') then raise exception 'plano invalido'; end if;
  update public.profiles set plan = p_plan where id = p_id and role <> 'master';
end $$;
revoke execute on function public.set_plan(uuid,text) from public, anon;
grant execute on function public.set_plan(uuid,text) to authenticated;

-- Limites por plano (Relatorios e Produtividade)
create table if not exists public.plan_limits (
  plan text primary key check (plan in ('basico','profissional','premium')), rel int, fichas int);
insert into public.plan_limits values ('basico',10,5),('profissional',50,20),('premium',null,null) on conflict (plan) do nothing;
alter table public.plan_limits enable row level security;
create policy "limites le" on public.plan_limits for select to authenticated using (true);
create policy "limites master atualiza" on public.plan_limits for update to authenticated using (public.is_master()) with check (public.is_master());
revoke all on public.plan_limits from anon;
revoke insert, delete on public.plan_limits from authenticated;
create or replace function public.check_limits() returns trigger language plpgsql security definer set search_path=public as $$
declare pl text; rl text; lim int; n int; o int;
begin
  if new.key not in ('enf_rel','enf_fichas') or jsonb_typeof(new.value) <> 'array' then return new; end if;
  select plan, role into pl, rl from public.profiles where id = new.user_id;
  if rl = 'master' or pl is null then return new; end if;
  select case when new.key='enf_rel' then rel else fichas end into lim from public.plan_limits where plan = pl;
  if lim is null then return new; end if;
  n := jsonb_array_length(new.value);
  o := case when tg_op='UPDATE' and jsonb_typeof(old.value)='array' then jsonb_array_length(old.value) else 0 end;
  if n > lim and n > o then raise exception 'limite do plano atingido'; end if;
  return new;
end $$;
revoke execute on function public.check_limits() from public, anon, authenticated;
drop trigger if exists app_data_limites on public.app_data;
create trigger app_data_limites before insert or update on public.app_data for each row execute function public.check_limits();
