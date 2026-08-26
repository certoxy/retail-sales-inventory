-- Phase 18: Tamper-resistant audit events, backup evidence and recovery drills.
-- Run once after 017_system_health.sql.

begin;

create table public.audit_events (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  branch_id uuid references public.branches(id),
  actor_id uuid references auth.users(id),
  action text not null,
  entity_type text not null,
  entity_id uuid,
  summary text not null,
  details jsonb not null default '{}'::jsonb
);
create index audit_events_created_idx on public.audit_events(created_at desc);
create index audit_events_branch_created_idx on public.audit_events(branch_id,created_at desc);
create index audit_events_entity_idx on public.audit_events(entity_type,entity_id);
alter table public.audit_events enable row level security;
create policy "admins read audit events" on public.audit_events for select to authenticated using(public.is_admin());

create or replace function public.capture_audit_event()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_new jsonb:=case when tg_op='DELETE' then '{}'::jsonb else to_jsonb(new) end;
        v_old jsonb:=case when tg_op='INSERT' then '{}'::jsonb else to_jsonb(old) end;
        v_row jsonb;v_id uuid;v_branch uuid;v_action text;v_summary text;v_details jsonb;
begin
  v_row:=case when tg_op='DELETE' then v_old else v_new end;
  begin v_id:=nullif(v_row->>'id','')::uuid; exception when others then v_id:=null; end;
  begin v_branch:=nullif(coalesce(v_row->>'branch_id',v_row->>'from_branch_id',v_row->>'to_branch_id'),'')::uuid; exception when others then v_branch:=null; end;
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
  insert into public.audit_events(branch_id,actor_id,action,entity_type,entity_id,summary,details)
  values(v_branch,auth.uid(),v_action,tg_table_name,v_id,v_summary,v_details);
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

do $$ declare t text;
begin
  foreach t in array array['sales','stock_movements','stock_transfers','purchase_orders','returns','cash_shifts','cash_movements','stocktakes','expenses','inventory_disposals','profiles','staff_branch_assignments'] loop
    execute format('drop trigger if exists audit_%I on public.%I',t,t);
    execute format('create trigger audit_%I after insert or update or delete on public.%I for each row execute function public.capture_audit_event()',t,t);
  end loop;
end $$;

create table public.backup_controls (
  id boolean primary key default true check(id),
  provider text,
  backup_enabled boolean not null default false,
  last_backup_at timestamptz,
  last_verified_at timestamptz,
  verified_by uuid references auth.users(id),
  evidence_reference text,
  retention_days integer check(retention_days is null or retention_days>0),
  recovery_contact text,
  notes text,
  updated_at timestamptz not null default now()
);
insert into public.backup_controls(id) values(true) on conflict(id) do nothing;
alter table public.backup_controls enable row level security;
create policy "admins read backup controls" on public.backup_controls for select to authenticated using(public.is_admin());

create table public.recovery_drills (
  id uuid primary key default gen_random_uuid(),
  performed_at timestamptz not null,
  environment text not null check(environment in ('sandbox','staging','test')),
  outcome text not null check(outcome in ('passed','partial','failed')),
  duration_minutes integer not null check(duration_minutes>0),
  restored_through timestamptz,
  evidence_reference text not null,
  notes text,
  performed_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now()
);
create index recovery_drills_performed_idx on public.recovery_drills(performed_at desc);
alter table public.recovery_drills enable row level security;
create policy "admins read recovery drills" on public.recovery_drills for select to authenticated using(public.is_admin());

create or replace function public.update_backup_controls(p_provider text,p_backup_enabled boolean,p_last_backup_at timestamptz,p_last_verified_at timestamptz,p_evidence_reference text,p_retention_days integer,p_recovery_contact text,p_notes text default null)
returns boolean language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_backup_enabled and (p_last_backup_at is null or p_last_verified_at is null or nullif(trim(p_evidence_reference),'') is null) then raise exception 'Backup date, verification date and evidence are required when backups are enabled'; end if;
  insert into backup_controls(id,provider,backup_enabled,last_backup_at,last_verified_at,verified_by,evidence_reference,retention_days,recovery_contact,notes,updated_at)
  values(true,nullif(trim(p_provider),''),p_backup_enabled,p_last_backup_at,p_last_verified_at,auth.uid(),nullif(trim(p_evidence_reference),''),p_retention_days,nullif(trim(p_recovery_contact),''),nullif(trim(p_notes),''),now())
  on conflict(id) do update set provider=excluded.provider,backup_enabled=excluded.backup_enabled,last_backup_at=excluded.last_backup_at,last_verified_at=excluded.last_verified_at,verified_by=excluded.verified_by,evidence_reference=excluded.evidence_reference,retention_days=excluded.retention_days,recovery_contact=excluded.recovery_contact,notes=excluded.notes,updated_at=now();
  insert into audit_events(actor_id,action,entity_type,summary,details) values(auth.uid(),'verified','backup_controls','Backup evidence updated',jsonb_build_object('provider',p_provider,'backup_enabled',p_backup_enabled,'last_backup_at',p_last_backup_at,'last_verified_at',p_last_verified_at,'retention_days',p_retention_days));
  return true;
end $$;

create or replace function public.record_recovery_drill(p_performed_at timestamptz,p_environment text,p_outcome text,p_duration_minutes integer,p_restored_through timestamptz,p_evidence_reference text,p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_environment not in ('sandbox','staging','test') or p_outcome not in ('passed','partial','failed') or p_duration_minutes<=0 or nullif(trim(p_evidence_reference),'') is null then raise exception 'Complete valid recovery-drill evidence is required'; end if;
  insert into recovery_drills(performed_at,environment,outcome,duration_minutes,restored_through,evidence_reference,notes) values(p_performed_at,p_environment,p_outcome,p_duration_minutes,p_restored_through,trim(p_evidence_reference),nullif(trim(p_notes),'')) returning id into v_id;
  insert into audit_events(actor_id,action,entity_type,entity_id,summary,details) values(auth.uid(),'recorded','recovery_drills',v_id,'Recovery drill recorded',jsonb_build_object('outcome',p_outcome,'environment',p_environment,'duration_minutes',p_duration_minutes));
  return v_id;
end $$;

create or replace function public.get_audit_log(p_branch_id uuid default null,p_from timestamptz default now()-interval '30 days',p_to timestamptz default now(),p_entity text default null,p_query text default null,p_limit integer default 250)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_result jsonb;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_result from (
    select a.id,a.created_at,a.branch_id,b.code branch_code,b.name branch_name,a.actor_id,coalesce(p.full_name,p.email,'System') actor_name,a.action,a.entity_type,a.entity_id,a.summary,a.details
    from audit_events a left join branches b on b.id=a.branch_id left join profiles p on p.id=a.actor_id
    where a.created_at between p_from and p_to and (p_branch_id is null or a.branch_id=p_branch_id) and (p_entity is null or a.entity_type=p_entity)
      and (nullif(trim(p_query),'') is null or a.summary ilike '%'||trim(p_query)||'%' or a.action ilike '%'||trim(p_query)||'%' or coalesce(p.full_name,p.email,'') ilike '%'||trim(p_query)||'%')
    order by a.created_at desc limit least(greatest(coalesce(p_limit,250),1),1000)
  ) x;
  return v_result;
end $$;

create or replace function public.get_backup_readiness()
returns jsonb language plpgsql security definer set search_path=public as $$
declare c backup_controls%rowtype;d recovery_drills%rowtype;v_checks jsonb;v_ready boolean;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select * into c from backup_controls where id=true;
  select * into d from recovery_drills order by performed_at desc limit 1;
  v_ready:=c.backup_enabled and c.last_backup_at>=now()-interval '48 hours' and c.last_verified_at>=now()-interval '30 days' and nullif(trim(c.evidence_reference),'') is not null and coalesce(c.retention_days,0)>=7 and nullif(trim(c.recovery_contact),'') is not null and d.outcome='passed' and d.performed_at>=now()-interval '90 days';
  v_checks:=jsonb_build_array(
    jsonb_build_object('label','Provider backups enabled','passed',c.backup_enabled),
    jsonb_build_object('label','Latest backup within 48 hours','passed',c.last_backup_at>=now()-interval '48 hours'),
    jsonb_build_object('label','Evidence verified within 30 days','passed',c.last_verified_at>=now()-interval '30 days' and nullif(trim(c.evidence_reference),'') is not null),
    jsonb_build_object('label','Retention is at least 7 days','passed',coalesce(c.retention_days,0)>=7),
    jsonb_build_object('label','Recovery contact assigned','passed',nullif(trim(c.recovery_contact),'') is not null),
    jsonb_build_object('label','Recovery drill passed within 90 days','passed',d.outcome='passed' and d.performed_at>=now()-interval '90 days')
  );
  return jsonb_build_object('status',case when v_ready then 'verified' when c.backup_enabled then 'attention' else 'not_configured' end,'controls',to_jsonb(c),'latest_drill',case when d.id is null then null else to_jsonb(d) end,'checks',v_checks,'drills',(select coalesce(jsonb_agg(to_jsonb(r) order by performed_at desc),'[]'::jsonb) from (select * from recovery_drills order by performed_at desc limit 25) r));
end $$;

create or replace function public.get_recovery_snapshot(p_branch_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() or not public.can_access_branch(p_branch_id) then raise exception 'Administrator branch access required'; end if;
  return jsonb_build_object('generated_at',now(),'branch',(select to_jsonb(b) from branches b where id=p_branch_id),
    'inventory',(select coalesce(jsonb_agg(to_jsonb(x) order by x.name),'[]'::jsonb) from (select p.id,p.sku,p.barcode,p.name,bp.selling_price,bp.quantity_on_hand,bp.reorder_level,bp.active from branch_products bp join products p on p.id=bp.product_id where bp.branch_id=p_branch_id) x),
    'recent_sales',(select coalesce(jsonb_agg(to_jsonb(s) order by created_at desc),'[]'::jsonb) from (select id,receipt_number,created_at,subtotal,vat_amount,total,payment_method,cashier_id from sales where branch_id=p_branch_id and created_at>=now()-interval '30 days' order by created_at desc) s),
    'recent_stock_movements',(select coalesce(jsonb_agg(to_jsonb(m) order by created_at desc),'[]'::jsonb) from (select id,product_id,movement_type,quantity_change,reference_id,notes,created_at from stock_movements where branch_id=p_branch_id and created_at>=now()-interval '30 days' order by created_at desc) m));
end $$;

revoke all on function public.update_backup_controls(text,boolean,timestamptz,timestamptz,text,integer,text,text) from public;
revoke all on function public.record_recovery_drill(timestamptz,text,text,integer,timestamptz,text,text) from public;
revoke all on function public.get_audit_log(uuid,timestamptz,timestamptz,text,text,integer) from public;
revoke all on function public.get_backup_readiness() from public;
revoke all on function public.get_recovery_snapshot(uuid) from public;
grant execute on function public.update_backup_controls(text,boolean,timestamptz,timestamptz,text,integer,text,text) to authenticated;
grant execute on function public.record_recovery_drill(timestamptz,text,text,integer,timestamptz,text,text) to authenticated;
grant execute on function public.get_audit_log(uuid,timestamptz,timestamptz,text,text,integer) to authenticated;
grant execute on function public.get_backup_readiness() to authenticated;
grant execute on function public.get_recovery_snapshot(uuid) to authenticated;
grant select on public.audit_events,public.backup_controls,public.recovery_drills to authenticated;

insert into public.system_settings(setting_key,setting_value) values('app_version','1.10.0'),('migration_version','018')
on conflict(setting_key) do update set setting_value=excluded.setting_value,updated_at=now();

commit;
