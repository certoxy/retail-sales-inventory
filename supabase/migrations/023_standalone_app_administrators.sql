-- Phase 23: Standalone platform administrators without organisation membership.
-- Run once after 022_tenant_login_recovery.sql.

begin;

create or replace function public.get_platform_admin_dashboard()
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 if not public.is_app_administrator() then raise exception 'App Administrator access required'; end if;
 return jsonb_build_object(
  'organizations',(select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'slug',o.slug,'active',o.active,'user_limit',c.user_limit,'member_count',(select count(*) from organization_memberships m where m.organization_id=o.id and m.active),'features',c.features) order by o.name),'[]'::jsonb) from organizations o join organization_controls c on c.organization_id=o.id),
  'app_administrators',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'email',p.email,'full_name',p.full_name,'active',a.active,'granted_at',a.created_at,'has_organization_membership',exists(select 1 from organization_memberships m where m.user_id=a.user_id)) order by coalesce(p.full_name,p.email)),'[]'::jsonb) from app_administrators a join profiles p on p.id=a.user_id)
 );
end $$;

create or replace function public.set_app_administrator(p_email text,p_enabled boolean)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_user uuid;v_active_admins integer;
begin
 if not public.is_app_administrator() then raise exception 'App Administrator access required'; end if;
 select id into v_user from profiles where lower(email)=lower(trim(p_email));
 if v_user is null then raise exception 'No RetailFlow Auth user found for this email. Create the user in Supabase Authentication first'; end if;
 if p_enabled and exists(select 1 from organization_memberships where user_id=v_user) then
  raise exception 'App Administrators must be platform-only and cannot belong to an organisation';
 end if;
 if not p_enabled then
  select count(*) into v_active_admins from app_administrators where active;
  if v_active_admins<=1 then raise exception 'At least one active App Administrator is required'; end if;
 end if;
 insert into app_administrators(user_id,active,granted_by) values(v_user,p_enabled,auth.uid())
 on conflict(user_id) do update set active=excluded.active,granted_by=auth.uid(),created_at=now();
 return true;
end $$;

revoke all on function public.get_platform_admin_dashboard(),public.set_app_administrator(text,boolean) from public;
grant execute on function public.get_platform_admin_dashboard(),public.set_app_administrator(text,boolean) to authenticated;

update public.system_settings set setting_value='2.2.0',updated_at=now() where setting_key='app_version';
update public.system_settings set setting_value='023',updated_at=now() where setting_key='migration_version';

commit;
