-- Phase 22: Recover tenant login resolution after organisation controls.
-- Run once after 021_tenant_administration.sql.

begin;

-- v2.1 introduced suspension controls. Existing organisations predate those
-- controls and must remain active during the upgrade.
update public.organizations set active=true,updated_at=now()
where exists(select 1 from public.organization_memberships m where m.organization_id=organizations.id);

create or replace function public.get_tenant_session_context()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_result jsonb;
begin
 if auth.uid() is null then raise exception 'Authentication required'; end if;
 select jsonb_build_object(
   'has_membership',true,
   'membership_active',m.active,
   'role',m.role,
   'organization',jsonb_build_object('id',o.id,'name',o.name,'slug',o.slug,'active',o.active),
   'is_app_admin',public.is_app_administrator(auth.uid()),
   'features',coalesce(c.features,'{}'::jsonb)
 ) into v_result
 from organization_memberships m
 join organizations o on o.id=m.organization_id
 left join organization_controls c on c.organization_id=o.id
 where m.user_id=auth.uid()
 order by m.created_at limit 1;
 return coalesce(v_result,jsonb_build_object(
   'has_membership',false,'membership_active',false,'role',null,
   'organization',null,'is_app_admin',public.is_app_administrator(auth.uid()),'features','{}'::jsonb
 ));
end $$;

revoke all on function public.get_tenant_session_context() from public;
grant execute on function public.get_tenant_session_context() to authenticated;

update public.system_settings set setting_value='2.1.1',updated_at=now() where setting_key='app_version';
update public.system_settings set setting_value='022',updated_at=now() where setting_key='migration_version';

commit;
