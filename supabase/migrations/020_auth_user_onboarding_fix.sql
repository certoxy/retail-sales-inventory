-- Phase 20: Allow Auth profile creation before a new user has an organisation.
-- Run once after 019_multitenant_foundation.sql.

begin;

create or replace function public.capture_audit_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_new jsonb:=case when tg_op='DELETE' then '{}'::jsonb else to_jsonb(new) end;
        v_old jsonb:=case when tg_op='INSERT' then '{}'::jsonb else to_jsonb(old) end;
        v_row jsonb;v_id uuid;v_branch uuid;v_org uuid;v_action text;v_summary text;v_details jsonb;
begin
  v_row:=case when tg_op='DELETE' then v_old else v_new end;
  begin v_id:=nullif(v_row->>'id','')::uuid; exception when others then v_id:=null; end;
  begin v_branch:=nullif(coalesce(v_row->>'branch_id',v_row->>'from_branch_id',v_row->>'to_branch_id'),'')::uuid; exception when others then v_branch:=null; end;
  select organization_id into v_org from public.branches where id=v_branch;
  v_org:=coalesce(v_org,public.current_organization_id());

  -- auth.users creates the public profile before the user can join or create an
  -- organisation. That pre-membership insert has no tenant to own an audit row.
  if v_org is null then
    if tg_op='DELETE' then return old; end if;
    return new;
  end if;

  v_action:=lower(tg_op);
  if tg_op='UPDATE' and coalesce(v_old->>'status','') is distinct from coalesce(v_new->>'status','') then
    v_action:='status_changed';
    v_summary:=format('%s status changed from %s to %s',replace(tg_table_name,'_',' '),coalesce(v_old->>'status','—'),coalesce(v_new->>'status','—'));
  else
    v_summary:=format('%s %s',replace(tg_table_name,'_',' '),lower(tg_op));
  end if;
  v_details:=jsonb_strip_nulls(jsonb_build_object(
    'operation',tg_op,'old_status',v_old->>'status','new_status',v_new->>'status',
    'amount',coalesce(v_new->>'amount',v_old->>'amount'),'quantity',coalesce(v_new->>'quantity_change',v_new->>'quantity',v_old->>'quantity_change',v_old->>'quantity'),
    'reason',coalesce(v_new->>'reason',v_old->>'reason'),'reference',coalesce(v_new->>'reference_number',v_new->>'evidence_reference',v_old->>'reference_number',v_old->>'evidence_reference')
  ));
  insert into public.audit_events(organization_id,branch_id,actor_id,action,entity_type,entity_id,summary,details)
  values(v_org,v_branch,auth.uid(),v_action,tg_table_name,v_id,v_summary,v_details);
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

update public.system_settings set setting_value='2.0.1',updated_at=now() where setting_key='app_version';
update public.system_settings set setting_value='020',updated_at=now() where setting_key='migration_version';

commit;
