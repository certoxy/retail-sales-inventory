-- Phase 21: Platform administration, organisation limits, feature controls and secure invitations.
-- Run once after 020_auth_user_onboarding_fix.sql.

begin;

create table public.app_administrators (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  active boolean not null default true,
  granted_by uuid references public.profiles(id),
  created_at timestamptz not null default now()
);

create table public.organization_controls (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  user_limit integer not null default 10 check(user_limit>0),
  features jsonb not null default '{"dashboard":true,"sales_history":true,"cashier_shifts":true,"returns":true,"expenses":true,"inventory_disposal":true,"stocktake":true,"inventory":true,"purchasing":true,"reorder":true,"transfers":true,"offline_sales":true,"system_health":true,"audit_recovery":true}'::jsonb,
  updated_by uuid references public.profiles(id),
  updated_at timestamptz not null default now()
);

create table public.organization_invitations (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  email text not null,
  full_name text,
  role public.staff_role not null default 'cashier',
  branch_ids uuid[] not null default '{}',
  token uuid not null unique default gen_random_uuid(),
  status text not null default 'pending' check(status in('pending','accepted','cancelled','expired')),
  invited_by uuid not null references public.profiles(id),
  accepted_by uuid references public.profiles(id),
  expires_at timestamptz not null default now()+interval '7 days',
  accepted_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index organization_pending_invite_email_uidx on public.organization_invitations(organization_id,lower(email)) where status='pending';
create index organization_invitations_token_idx on public.organization_invitations(token,status);

insert into public.organization_controls(organization_id)
select id from public.organizations on conflict do nothing;

create or replace function public.initialize_organization_controls()
returns trigger language plpgsql security definer set search_path=public as $$
begin insert into organization_controls(organization_id) values(new.id) on conflict do nothing;return new;end $$;
create trigger initialize_organization_controls_after_insert after insert on public.organizations for each row execute function public.initialize_organization_controls();

-- The creator of the first migrated organisation becomes the initial App Administrator.
insert into public.app_administrators(user_id,granted_by)
select coalesce(o.created_by,m.user_id),coalesce(o.created_by,m.user_id)
from public.organizations o
left join lateral(select user_id from public.organization_memberships where organization_id=o.id and role='admin' order by created_at limit 1)m on true
where coalesce(o.created_by,m.user_id) is not null order by o.created_at limit 1
on conflict(user_id) do update set active=true;

create or replace function public.is_app_administrator(p_user_id uuid default auth.uid())
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from app_administrators where user_id=p_user_id and active);
$$;

create or replace function public.current_organization_id()
returns uuid language sql stable security definer set search_path=public as $$
 select m.organization_id from organization_memberships m join organizations o on o.id=m.organization_id
 where m.user_id=auth.uid() and m.active and o.active order by m.created_at limit 1;
$$;

create or replace function public.is_organization_member(p_organization_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from organization_memberships m join organizations o on o.id=m.organization_id
 where m.organization_id=p_organization_id and m.user_id=auth.uid() and m.active and o.active);
$$;

create or replace function public.is_organization_admin(p_organization_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from organization_memberships m join organizations o on o.id=m.organization_id
 where m.organization_id=p_organization_id and m.user_id=auth.uid() and m.active and m.role='admin' and o.active);
$$;

alter table public.app_administrators enable row level security;
alter table public.organization_controls enable row level security;
alter table public.organization_invitations enable row level security;

create policy "app admins read platform admins" on public.app_administrators for select to authenticated using(public.is_app_administrator());
create policy "members read organisation controls" on public.organization_controls for select to authenticated using(public.is_organization_member(organization_id) or public.is_app_administrator());
create policy "admins read invitations" on public.organization_invitations for select to authenticated using(public.is_organization_admin(organization_id) or public.is_app_administrator());

drop policy if exists "members read organizations" on public.organizations;
create policy "members or app admins read organizations" on public.organizations for select to authenticated using(public.is_organization_member(id) or public.is_app_administrator());

create or replace function public.get_current_access_context()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid:=public.current_organization_id();v_features jsonb;
begin
 select features into v_features from organization_controls where organization_id=v_org;
 return jsonb_build_object('organization_id',v_org,'is_app_admin',public.is_app_administrator(),'features',coalesce(v_features,'{}'::jsonb));
end $$;

create or replace function public.get_organization_access_dashboard()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_org uuid:=public.current_organization_id();v_result jsonb;
begin
 if v_org is null or not public.is_organization_admin(v_org) then raise exception 'Organisation Administrator access required'; end if;
 update organization_invitations set status='expired' where organization_id=v_org and status='pending' and expires_at<=now();
 select jsonb_build_object(
  'members',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'email',p.email,'full_name',p.full_name,'role',m.role,'active',m.active,'branches',coalesce((select jsonb_agg(b.code order by b.code) from staff_branch_assignments a join branches b on b.id=a.branch_id where a.staff_id=p.id),'[]'::jsonb)) order by coalesce(p.full_name,p.email)),'[]'::jsonb) from organization_memberships m join profiles p on p.id=m.user_id where m.organization_id=v_org),
  'invitations',(select coalesce(jsonb_agg(jsonb_build_object('id',i.id,'email',i.email,'full_name',i.full_name,'role',i.role,'status',i.status,'expires_at',i.expires_at,'token',i.token,'branch_ids',i.branch_ids) order by i.created_at desc),'[]'::jsonb) from organization_invitations i where i.organization_id=v_org and i.status='pending'),
  'controls',(select to_jsonb(c) from organization_controls c where c.organization_id=v_org)
 ) into v_result;
 return v_result;
end $$;

create or replace function public.create_organization_invitation(p_email text,p_full_name text,p_role public.staff_role,p_branch_ids uuid[] default '{}')
returns uuid language plpgsql security definer set search_path=public as $$
declare v_org uuid:=public.current_organization_id();v_limit integer;v_used integer;v_token uuid;
begin
 if v_org is null or not public.is_organization_admin(v_org) then raise exception 'Organisation Administrator access required'; end if;
 if p_email !~* '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then raise exception 'A valid email address is required'; end if;
 if p_role not in('admin','cashier') then raise exception 'Invalid organisation role'; end if;
 if exists(select 1 from organization_memberships m join profiles p on p.id=m.user_id where m.organization_id=v_org and lower(p.email)=lower(trim(p_email))) then raise exception 'This user already belongs to the organisation'; end if;
 select user_limit into v_limit from organization_controls where organization_id=v_org;
 select (select count(*) from organization_memberships where organization_id=v_org and active)+(select count(*) from organization_invitations where organization_id=v_org and status='pending' and expires_at>now()) into v_used;
 if v_used>=v_limit then raise exception 'The organisation has reached its user limit of %',v_limit; end if;
 if exists(select 1 from unnest(coalesce(p_branch_ids,'{}')) x left join branches b on b.id=x and b.organization_id=v_org where b.id is null) then raise exception 'Invalid branch assignment'; end if;
 insert into organization_invitations(organization_id,email,full_name,role,branch_ids,invited_by)
 values(v_org,lower(trim(p_email)),nullif(trim(p_full_name),''),p_role,case when p_role='admin' then '{}' else coalesce(p_branch_ids,'{}') end,auth.uid()) returning token into v_token;
 insert into audit_events(organization_id,actor_id,action,entity_type,summary,details) values(v_org,auth.uid(),'invited','organization_invitations','User invitation created',jsonb_build_object('email',lower(trim(p_email)),'role',p_role));
 return v_token;
end $$;

create or replace function public.accept_organization_invitation(p_token uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare i organization_invitations%rowtype;v_email text;
begin
 if auth.uid() is null then raise exception 'Sign in to accept this invitation'; end if;
 select lower(email) into v_email from profiles where id=auth.uid();
 select * into i from organization_invitations where token=p_token and status='pending' for update;
 if i.id is null or i.expires_at<=now() then raise exception 'This invitation is invalid or has expired'; end if;
 if v_email<>lower(i.email) then raise exception 'Sign in with the invited email address'; end if;
 if exists(select 1 from organization_memberships where user_id=auth.uid()) then raise exception 'This account already belongs to an organisation'; end if;
 insert into organization_memberships(organization_id,user_id,role,active) values(i.organization_id,auth.uid(),i.role,true);
 update profiles set full_name=coalesce(nullif(full_name,''),i.full_name),role=i.role,active=true,updated_at=now() where id=auth.uid();
 if i.role='admin' then insert into staff_branch_assignments(staff_id,branch_id) select auth.uid(),id from branches where organization_id=i.organization_id on conflict do nothing;
 else insert into staff_branch_assignments(staff_id,branch_id) select auth.uid(),id from branches where organization_id=i.organization_id and id=any(i.branch_ids) on conflict do nothing; end if;
 update organization_invitations set status='accepted',accepted_by=auth.uid(),accepted_at=now() where id=i.id;
 insert into audit_events(organization_id,actor_id,action,entity_type,entity_id,summary,details) values(i.organization_id,auth.uid(),'accepted','organization_invitations',i.id,'Organisation invitation accepted',jsonb_build_object('email',i.email,'role',i.role));
 return i.organization_id;
end $$;

create or replace function public.cancel_organization_invitation(p_invitation_id uuid)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_org uuid;
begin
 select organization_id into v_org from organization_invitations where id=p_invitation_id;
 if v_org is null or not(public.is_organization_admin(v_org) or public.is_app_administrator()) then raise exception 'Administrator access required'; end if;
 update organization_invitations set status='cancelled' where id=p_invitation_id and status='pending';return found;
end $$;

create or replace function public.update_organization_member(p_user_id uuid,p_role public.staff_role default null,p_active boolean default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_org uuid:=public.current_organization_id();
begin
 if v_org is null or not public.is_organization_admin(v_org) then raise exception 'Organisation Administrator access required'; end if;
 if p_user_id=auth.uid() and p_active=false then raise exception 'You cannot deactivate your own account'; end if;
 if p_user_id=auth.uid() and p_role='cashier' then raise exception 'Another administrator must change your role'; end if;
 update organization_memberships set role=coalesce(p_role,role),active=coalesce(p_active,active),updated_at=now() where organization_id=v_org and user_id=p_user_id;
 if not found then raise exception 'User is not part of this organisation'; end if;
 update profiles set role=coalesce(p_role,role),active=coalesce(p_active,active),updated_at=now() where id=p_user_id;
 if p_role='admin' then insert into staff_branch_assignments(staff_id,branch_id) select p_user_id,id from branches where organization_id=v_org on conflict do nothing; end if;
 return true;
end $$;

create or replace function public.get_platform_admin_dashboard()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not public.is_app_administrator() then raise exception 'App Administrator access required'; end if;
 return jsonb_build_object('organizations',(select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'slug',o.slug,'active',o.active,'user_limit',c.user_limit,'member_count',(select count(*) from organization_memberships m where m.organization_id=o.id and m.active),'features',c.features) order by o.name),'[]'::jsonb) from organizations o join organization_controls c on c.organization_id=o.id));
end $$;

create or replace function public.update_organization_controls(p_organization_id uuid,p_active boolean,p_user_limit integer,p_features jsonb)
returns boolean language plpgsql security definer set search_path=public as $$
begin
 if not public.is_app_administrator() then raise exception 'App Administrator access required'; end if;
 if p_user_limit<1 or p_user_limit<(select count(*) from organization_memberships where organization_id=p_organization_id and active) then raise exception 'User limit cannot be below the number of active users'; end if;
 update organizations set active=p_active,updated_at=now() where id=p_organization_id;
 update organization_controls set user_limit=p_user_limit,features=p_features,updated_by=auth.uid(),updated_at=now() where organization_id=p_organization_id;
 return true;
end $$;

create or replace function public.set_app_administrator(p_email text,p_enabled boolean)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_user uuid;
begin
 if not public.is_app_administrator() then raise exception 'App Administrator access required'; end if;
 select id into v_user from profiles where lower(email)=lower(trim(p_email));if v_user is null then raise exception 'No RetailFlow user found for this email';end if;
 insert into app_administrators(user_id,active,granted_by) values(v_user,p_enabled,auth.uid()) on conflict(user_id) do update set active=excluded.active,granted_by=auth.uid();return true;
end $$;

revoke all on function public.get_current_access_context(),public.get_organization_access_dashboard(),public.create_organization_invitation(text,text,public.staff_role,uuid[]),public.accept_organization_invitation(uuid),public.cancel_organization_invitation(uuid),public.update_organization_member(uuid,public.staff_role,boolean),public.get_platform_admin_dashboard(),public.update_organization_controls(uuid,boolean,integer,jsonb),public.set_app_administrator(text,boolean) from public;
grant execute on function public.get_current_access_context(),public.get_organization_access_dashboard(),public.create_organization_invitation(text,text,public.staff_role,uuid[]),public.accept_organization_invitation(uuid),public.cancel_organization_invitation(uuid),public.update_organization_member(uuid,public.staff_role,boolean),public.get_platform_admin_dashboard(),public.update_organization_controls(uuid,boolean,integer,jsonb),public.set_app_administrator(text,boolean) to authenticated;

update public.system_settings set setting_value='2.1.0',updated_at=now() where setting_key='app_version';
update public.system_settings set setting_value='021',updated_at=now() where setting_key='migration_version';

commit;
