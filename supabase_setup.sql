-- ============================================================
-- 空中画板 · Supabase 初始化脚本
--
-- 用法：Supabase 后台 → 左侧「SQL Editor」→ New query → 整段粘贴 → Run
-- 可以重复执行，不报错、不重复建表、不丢数据。
-- ============================================================


-- ---------- 1. 作品表 ----------
create table if not exists public.artworks (
  id          text primary key,
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title       text not null default '未命名',
  module      text not null default 'free' check (module in ('free', 'challenge')),
  target_id   text,
  score       int,
  w           int,
  h           int,
  thumb_url   text,
  full_url    text,
  bytes       int default 0,
  created_at  timestamptz not null default now()
);

create index if not exists artworks_user_time_idx
  on public.artworks (user_id, created_at desc);


-- ---------- 2. 行级权限：只能读写自己的作品 ----------
alter table public.artworks enable row level security;

drop policy if exists "read own artworks"   on public.artworks;
drop policy if exists "insert own artworks" on public.artworks;
drop policy if exists "update own artworks" on public.artworks;
drop policy if exists "delete own artworks" on public.artworks;

create policy "read own artworks"
  on public.artworks for select
  using (auth.uid() = user_id);

create policy "insert own artworks"
  on public.artworks for insert
  with check (auth.uid() = user_id);

create policy "update own artworks"
  on public.artworks for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

create policy "delete own artworks"
  on public.artworks for delete
  using (auth.uid() = user_id);


-- ---------- 3. 图片存储桶（public 读，路径不可枚举） ----------
insert into storage.buckets (id, name, public)
values ('artworks', 'artworks', true)
on conflict (id) do nothing;

drop policy if exists "read artworks bucket"      on storage.objects;
drop policy if exists "write own artwork files"   on storage.objects;
drop policy if exists "delete own artwork files"  on storage.objects;

create policy "read artworks bucket"
  on storage.objects for select
  using (bucket_id = 'artworks');

-- 文件路径形如 {user_id}/{作品id}_full.jpg，第一段必须等于自己的 uid
create policy "write own artwork files"
  on storage.objects for insert
  with check (
    bucket_id = 'artworks'
    and auth.uid()::text = (storage.foldername(name))[1]
  );

create policy "delete own artwork files"
  on storage.objects for delete
  using (
    bucket_id = 'artworks'
    and auth.uid()::text = (storage.foldername(name))[1]
  );


-- ---------- 4. 表权限 ----------
-- 用 SQL Editor 建表不会自动继承 anon / authenticated 的授权，
-- 少了这一段，登录后访问会报 permission denied for table artworks。
grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on public.artworks to authenticated;
grant select on public.artworks to anon;   -- 未登录也能查，但 RLS 会把它过滤成空数组


-- ---------- 5. 自动确认邮箱 ----------
-- 本项目的用户名会被拼成 用户名@aircanvas.app 这样的虚拟邮箱，收不到确认信，
-- 而项目默认开启「Confirm email」，会导致注册后一直登不进去。
-- 这里在 auth.users 插入后直接把邮箱标记为已验证，等价于关掉邮箱确认。
create or replace function public.auto_confirm_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  update auth.users
     set email_confirmed_at = coalesce(email_confirmed_at, now())
   where id = new.id
     and email_confirmed_at is null;
  return new;
exception when others then
  -- 万一没有 auth.users 的写权限，也不要让注册整个失败
  return new;
end;
$$;

drop trigger if exists trg_auto_confirm_new_user on auth.users;
create trigger trg_auto_confirm_new_user
  after insert on auth.users
  for each row execute function public.auto_confirm_new_user();

-- 把之前注册过但没确认的账号补一次
update auth.users
   set email_confirmed_at = now()
 where email_confirmed_at is null;


-- ---------- 6. 自检 ----------
select 'artworks 表已就绪' as 状态, count(*) as 现有作品数 from public.artworks;
select 'artworks 存储桶已就绪' as 状态, public as 是否公开读 from storage.buckets where id = 'artworks';
select '自动确认邮箱已开启' as 状态, count(*) as 触发器数量
  from pg_trigger where tgname = 'trg_auto_confirm_new_user';
