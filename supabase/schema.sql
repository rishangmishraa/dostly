-- DOSTLY Supabase schema. Run the entire script in Supabase SQL Editor.
-- This schema uses one conversations table for both private and group chats.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  user_id text not null unique check (user_id ~ '^DST-[A-F0-9]{8}$'),
  display_name text not null default 'Dostly User' check (char_length(display_name) between 1 and 60),
  bio text not null default '' check (char_length(bio) <= 250),
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists profiles_user_id_idx on public.profiles(user_id);
alter table public.profiles enable row level security;

create or replace function public.protect_profile_identity()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.id is distinct from old.id or new.user_id is distinct from old.user_id then
    raise exception 'Dostly account ID cannot be changed';
  end if;
  new.updated_at := now(); return new;
end; $$;
drop trigger if exists protect_profile_identity_trigger on public.profiles;
create trigger protect_profile_identity_trigger before update on public.profiles for each row execute function public.protect_profile_identity();

create or replace function public.handle_new_dostly_user()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.profiles(id,user_id,display_name)
  values(new.id,'DST-' || upper(substr(replace(new.id::text,'-',''),1,8)),coalesce(nullif(left(trim(new.raw_user_meta_data ->> 'display_name'),60),''),'Dostly User'))
  on conflict (id) do nothing;
  return new;
end; $$;
drop trigger if exists on_dostly_user_created on auth.users;
create trigger on_dostly_user_created after insert on auth.users for each row execute function public.handle_new_dostly_user();

drop policy if exists "Authenticated users can view profiles" on public.profiles;
create policy "Authenticated users can view profiles" on public.profiles for select to authenticated using (true);
drop policy if exists "Users update their own profiles" on public.profiles;
create policy "Users update their own profiles" on public.profiles for update to authenticated using ((select auth.uid())=id) with check ((select auth.uid())=id);
grant select, update on public.profiles to authenticated;

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('private','group')),
  title text,
  avatar_path text,
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((kind='private' and title is null) or kind='group')
);
create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
member_role text not null default 'member' check (member_role in ('member','admin')),
  joined_at timestamptz not null default now(),
  primary key(conversation_id,user_id)
);
create index if not exists conversation_members_user_idx on public.conversation_members(user_id,conversation_id);

create or replace function public.is_conversation_member(cid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.conversation_members cm where cm.conversation_id=cid and cm.user_id=(select auth.uid()));
$$;
create or replace function public.is_conversation_admin(cid uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from public.conversation_members cm where cm.conversation_id=cid and cm.user_id=(select auth.uid()) and cm.member_role='admin');
$$;
revoke all on function public.is_conversation_member(uuid) from public;
revoke all on function public.is_conversation_admin(uuid) from public;
grant execute on function public.is_conversation_member(uuid) to authenticated;
grant execute on function public.is_conversation_admin(uuid) to authenticated;

alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
drop policy if exists "Members can read their conversations" on public.conversations;
create policy "Members can read their conversations" on public.conversations for select to authenticated using (public.is_conversation_member(id));
drop policy if exists "Authenticated users can create conversations" on public.conversations;
create policy "Authenticated users can create conversations" on public.conversations for insert to authenticated with check (created_by=(select auth.uid()));
drop policy if exists "Group admins can update conversations" on public.conversations;
create policy "Group admins can update conversations" on public.conversations for update to authenticated using (kind='group' and public.is_conversation_admin(id)) with check (kind='group' and public.is_conversation_admin(id));
drop policy if exists "Members can see conversation membership" on public.conversation_members;
create policy "Members can see conversation membership" on public.conversation_members for select to authenticated using (public.is_conversation_member(conversation_id));
drop policy if exists "Creator can add initial members" on public.conversation_members;
create policy "Creator can add initial members" on public.conversation_members for insert to authenticated with check (
  (exists(select 1 from public.conversations c where c.id=conversation_id and c.created_by=(select auth.uid())) and not exists(select 1 from public.conversation_members cm where cm.conversation_id=conversation_id))
  or (public.is_conversation_admin(conversation_id) and member_role='member' and exists(select 1 from public.conversations c where c.id=conversation_id and c.kind='group'))
);
drop policy if exists "Group admins can remove members" on public.conversation_members;
create policy "Group admins can remove members" on public.conversation_members for delete to authenticated using (public.is_conversation_admin(conversation_id) and exists(select 1 from public.conversations c where c.id=conversation_id and c.kind='group'));
revoke all on public.conversations, public.conversation_members from anon;
grant select, insert, update on public.conversations to authenticated;
grant select, insert, delete on public.conversation_members to authenticated;

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  body text not null default '',
  kind text not null default 'text' check(kind in ('text','image','file')),
  storage_path text,
  mime_type text,
  file_size bigint check(file_size is null or file_size between 0 and 10485760),
  created_at timestamptz not null default now(),
  check ((kind='text' and storage_path is null) or (kind in ('image','file') and storage_path is not null))
);
create index if not exists messages_conversation_created_idx on public.messages(conversation_id,created_at);
alter table public.messages enable row level security;
drop policy if exists "Members can read messages" on public.messages;
create policy "Members can read messages" on public.messages for select to authenticated using (public.is_conversation_member(conversation_id));
drop policy if exists "Members can send as themselves" on public.messages;
create policy "Members can send as themselves" on public.messages for insert to authenticated with check (sender_id=(select auth.uid()) and public.is_conversation_member(conversation_id) and (kind='text' or storage_path like (sender_id::text || '/' || conversation_id::text || '/%') or storage_path like (sender_id::text || '/status-%')));
grant select, insert on public.messages to authenticated;

create table if not exists public.statuses (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check(kind in ('text','image')),
  body text not null default '' check(char_length(body)<=500),
  storage_path text,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now()+interval '24 hours'),
  check ((kind='text' and storage_path is null and char_length(body)>0) or (kind='image' and storage_path is not null))
);
create index if not exists statuses_active_idx on public.statuses(expires_at desc);
alter table public.statuses enable row level security;
drop policy if exists "Signed-in users can view active statuses" on public.statuses;
create policy "Signed-in users can view active statuses" on public.statuses for select to authenticated using (expires_at>now());
drop policy if exists "Users create their own statuses" on public.statuses;
create policy "Users create their own statuses" on public.statuses for insert to authenticated with check (user_id=(select auth.uid()) and expires_at>now() and expires_at<=now()+interval '24 hours 5 minutes' and (storage_path is null or storage_path like (user_id::text || '/status-%')));
drop policy if exists "Users delete their own statuses" on public.statuses;
create policy "Users delete their own statuses" on public.statuses for delete to authenticated using(user_id=(select auth.uid()));
grant select,insert,delete on public.statuses to authenticated;

-- Private object storage. Files are never made public; client creates short-lived signed URLs.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('dostly-files','dostly-files',false,10485760,array['image/jpeg','image/png','image/gif','image/webp','application/pdf','text/plain','application/zip'])
on conflict(id) do update set public=false,file_size_limit=10485760,allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "Users upload files to their own folder" on storage.objects;
create policy "Users upload files to their own folder" on storage.objects for insert to authenticated with check(bucket_id='dostly-files' and (storage.foldername(name))[1]=(select auth.uid())::text);
drop policy if exists "Users can read authorized Dostly files" on storage.objects;
create policy "Users can read authorized Dostly files" on storage.objects for select to authenticated using (
 bucket_id='dostly-files' and (
   (storage.foldername(name))[1]=(select auth.uid())::text
   or exists(select 1 from public.messages m where m.storage_path=name and public.is_conversation_member(m.conversation_id))
   or exists(select 1 from public.statuses s where s.storage_path=name and s.expires_at>now())
   or exists(select 1 from public.profiles p where p.avatar_path=name)
 )
);
drop policy if exists "Users delete their own files" on storage.objects;
create policy "Users delete their own files" on storage.objects for delete to authenticated using(bucket_id='dostly-files' and (storage.foldername(name))[1]=(select auth.uid())::text);
grant usage on schema public to authenticated;

-- Realtime publications are needed for live message updates.
do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; when others then
  if sqlstate <> '42710' then raise; end if;
end $$;
