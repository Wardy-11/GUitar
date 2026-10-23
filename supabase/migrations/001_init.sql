-- FRET//FORGE schema. Run in Supabase SQL editor (or `supabase db push`).
create table profiles (
  id uuid primary key references auth.users on delete cascade,
  username text unique not null check (username ~ '^[a-z0-9_]{3,20}$'),
  share_live boolean not null default true,
  live_since timestamptz, live_seen timestamptz, live_focus text,
  created_at timestamptz not null default now()
);
create table sessions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references profiles on delete cascade,
  focus text not null default 'Free practice',
  started_at timestamptz not null default now(),
  ended_at timestamptz,
  seconds int not null default 0 check (seconds between 0 and 14400),
  notes text check (char_length(notes) <= 500)
);
create index on sessions (user_id, started_at desc);
create table friendships (
  requester uuid not null references profiles on delete cascade,
  addressee uuid not null references profiles on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  primary key (requester, addressee), check (requester <> addressee)
);
create index on friendships (addressee);

alter table profiles enable row level security;
alter table sessions enable row level security;
alter table friendships enable row level security;

create function are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from friendships where status = 'accepted'
    and ((requester = a and addressee = b) or (requester = b and addressee = a)))
$$;

create policy "own or friend profiles" on profiles for select to authenticated
  using (id = auth.uid() or are_friends(auth.uid(), id));
create policy "update own profile" on profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());
revoke update on profiles from authenticated;
grant update (share_live) on profiles to authenticated;   -- presence is written only by RPCs

create policy "own sessions" on sessions for select to authenticated using (user_id = auth.uid());
-- no insert/update policies: sessions are written only by start_session / end_session

create policy "see own friendships" on friendships for select to authenticated
  using (auth.uid() in (requester, addressee));
create policy "accept request" on friendships for update to authenticated
  using (addressee = auth.uid()) with check (addressee = auth.uid() and status = 'accepted');
create policy "remove friendship" on friendships for delete to authenticated
  using (auth.uid() in (requester, addressee));
revoke update on friendships from authenticated;
grant update (status) on friendships to authenticated;

-- Create a profile on signup; username comes from signUp options.data.username
create function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into profiles (id, username) values (new.id, lower(new.raw_user_meta_data->>'username'));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

-- Server-timed sessions: duration is computed here, so clients cannot inflate hours.
create function end_session(p_id uuid, p_notes text default null) returns int
language plpgsql security definer set search_path = public as $$
declare secs int;
begin
  update sessions set ended_at = now(), notes = left(p_notes, 500),
    seconds = least(14400, extract(epoch from now() - started_at)::int)
  where id = p_id and user_id = auth.uid() and ended_at is null returning seconds into secs;
  update profiles set live_since = null, live_seen = null, live_focus = null where id = auth.uid();
  return coalesce(secs, 0);
end $$;

create function start_session(p_focus text) returns uuid
language plpgsql security definer set search_path = public as $$
declare sid uuid; open_id uuid;
begin
  for open_id in select id from sessions where user_id = auth.uid() and ended_at is null loop
    perform end_session(open_id);
  end loop;
  insert into sessions (user_id, focus) values (auth.uid(), left(p_focus, 40)) returning id into sid;
  update profiles set live_since = now(), live_seen = now(), live_focus = left(p_focus, 40) where id = auth.uid();
  return sid;
end $$;

create function heartbeat() returns void
language sql security definer set search_path = public as $$
  update profiles set live_seen = now() where id = auth.uid() and live_since is not null
$$;

create function request_friend(uname text) returns text
language plpgsql security definer set search_path = public as $$
declare tid uuid;
begin
  select id into tid from profiles where username = lower(uname);
  if tid is null then return 'No guitarist with that username.'; end if;
  if tid = auth.uid() then return 'That''s you.'; end if;
  if exists (select 1 from friendships where (requester = auth.uid() and addressee = tid)
     or (requester = tid and addressee = auth.uid())) then return 'Already requested or friends.'; end if;
  insert into friendships (requester, addressee) values (auth.uid(), tid);
  return 'ok';
end $$;

create function my_requests() returns table (requester uuid, username text)
language sql stable security definer set search_path = public as $$
  select f.requester, p.username from friendships f join profiles p on p.id = f.requester
  where f.addressee = auth.uid() and f.status = 'pending'
$$;

-- Consecutive UTC days with >= 5 min practised, ending today or yesterday.
create function streak_for(u uuid) returns int
language sql stable security definer set search_path = public as $$
  with d as (
    select distinct (started_at at time zone 'UTC')::date as played_on
    from sessions where user_id = u and seconds >= 300
  ),
  g as (
    select played_on, played_on - (row_number() over (order by played_on))::int as grp from d
  ),
  l as (
    select count(*) as n, max(played_on) as last_day from g group by grp order by max(played_on) desc limit 1
  )
  select coalesce((select n::int from l where last_day >= (now() at time zone 'UTC')::date - 1), 0)
$$;

create function leaderboard() returns table (
  user_id uuid, username text, week_seconds int, streak int,
  live boolean, live_focus text, live_since timestamptz)
language sql stable security definer set search_path = public as $$
  select p.id, p.username,
    coalesce((select sum(s.seconds) from sessions s where s.user_id = p.id
      and s.started_at >= (date_trunc('week', now() at time zone 'UTC') at time zone 'UTC')), 0)::int,
    streak_for(p.id),
    (p.id <> auth.uid() and p.share_live and p.live_seen > now() - interval '3 minutes')
      or (p.id = auth.uid() and p.live_since is not null),
    case when p.share_live or p.id = auth.uid() then p.live_focus end,
    case when p.share_live or p.id = auth.uid() then p.live_since end
  from profiles p where p.id = auth.uid() or are_friends(auth.uid(), p.id)
  order by 3 desc
$$;

revoke execute on all functions in schema public from public, anon;
grant execute on function end_session, start_session, heartbeat, request_friend,
  my_requests, leaderboard to authenticated;

alter publication supabase_realtime add table profiles;
