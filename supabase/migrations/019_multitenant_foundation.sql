-- Phase 19: Multi-tenant organisation foundation and tenant isolation.
-- Run once after 018_audit_backup_recovery.sql.

begin;

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique check(slug ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  active boolean not null default true,
  created_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.organization_memberships (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.staff_role not null default 'cashier',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(organization_id,user_id),
  unique(user_id)
);

do $migration$
declare v_organization_id uuid;
begin
  insert into public.organizations(name,slug,created_by)
  values('RetailFlow Business','retailflow-business',(select id from auth.users order by created_at limit 1))
  returning id into v_organization_id;

  insert into public.organization_memberships(organization_id,user_id,role,active)
  select v_organization_id,id,role,active from public.profiles;

  alter table public.branches add column organization_id uuid references public.organizations(id);
  alter table public.categories add column organization_id uuid references public.organizations(id);
  alter table public.products add column organization_id uuid references public.organizations(id);
  alter table public.customers add column organization_id uuid references public.organizations(id);
  alter table public.suppliers add column organization_id uuid references public.organizations(id);
  alter table public.expense_categories add column organization_id uuid references public.organizations(id);
  alter table public.system_settings add column organization_id uuid references public.organizations(id);
  alter table public.audit_events add column organization_id uuid references public.organizations(id);
  alter table public.backup_controls add column organization_id uuid references public.organizations(id);
  alter table public.recovery_drills add column organization_id uuid references public.organizations(id);

  update public.branches set organization_id=v_organization_id where organization_id is null;
  update public.categories set organization_id=v_organization_id where organization_id is null;
  update public.products set organization_id=v_organization_id where organization_id is null;
  update public.customers set organization_id=v_organization_id where organization_id is null;
  update public.suppliers set organization_id=v_organization_id where organization_id is null;
  update public.expense_categories set organization_id=v_organization_id where organization_id is null;
  update public.system_settings set organization_id=v_organization_id where organization_id is null;
  update public.audit_events a set organization_id=coalesce((select b.organization_id from public.branches b where b.id=a.branch_id),v_organization_id) where organization_id is null;
  update public.backup_controls set organization_id=v_organization_id where organization_id is null;
  update public.recovery_drills set organization_id=v_organization_id where organization_id is null;
end $migration$;

alter table public.branches alter column organization_id set not null;
alter table public.categories alter column organization_id set not null;
alter table public.products alter column organization_id set not null;
alter table public.customers alter column organization_id set not null;
alter table public.suppliers alter column organization_id set not null;
alter table public.expense_categories alter column organization_id set not null;
alter table public.system_settings alter column organization_id set not null;
alter table public.audit_events alter column organization_id set not null;
alter table public.backup_controls alter column organization_id set not null;
alter table public.recovery_drills alter column organization_id set not null;

alter table public.branches drop constraint if exists branches_code_key;
alter table public.branches add constraint branches_organization_code_key unique(organization_id,code);
alter table public.categories drop constraint if exists categories_name_key;
alter table public.categories add constraint categories_organization_name_key unique(organization_id,name);
alter table public.products drop constraint if exists products_sku_key;
alter table public.products drop constraint if exists products_barcode_key;
alter table public.products add constraint products_organization_sku_key unique(organization_id,sku);
create unique index products_organization_barcode_uidx on public.products(organization_id,barcode) where barcode is not null;
alter table public.suppliers drop constraint if exists suppliers_name_key;
alter table public.suppliers add constraint suppliers_organization_name_key unique(organization_id,name);
alter table public.expense_categories drop constraint if exists expense_categories_name_key;
alter table public.expense_categories add constraint expense_categories_organization_name_key unique(organization_id,name);
alter table public.system_settings drop constraint if exists system_settings_pkey;
alter table public.system_settings add primary key(organization_id,setting_key);
alter table public.backup_controls drop constraint if exists backup_controls_pkey;
alter table public.backup_controls add primary key(organization_id,id);

create index branches_organization_idx on public.branches(organization_id,active,name);
create index products_organization_idx on public.products(organization_id,active,name);
create index memberships_user_idx on public.organization_memberships(user_id,active);
create index audit_events_organization_created_idx on public.audit_events(organization_id,created_at desc);

create or replace function public.current_organization_id()
returns uuid language sql stable security definer set search_path=public as $$
  select organization_id from organization_memberships
  where user_id=auth.uid() and active order by created_at limit 1;
$$;

create or replace function public.is_organization_member(p_organization_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from organization_memberships
    where organization_id=p_organization_id and user_id=auth.uid() and active);
$$;

create or replace function public.is_organization_admin(p_organization_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from organization_memberships
    where organization_id=p_organization_id and user_id=auth.uid() and active and role='admin');
$$;

create or replace function public.is_active_staff()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from profiles p join organization_memberships m on m.user_id=p.id
    where p.id=auth.uid() and p.active and m.active);
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from profiles p join organization_memberships m on m.user_id=p.id
    where p.id=auth.uid() and p.active and m.active and m.role='admin');
$$;

create or replace function public.can_access_branch(p_branch_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(
    select 1 from branches b
    join organization_memberships m on m.organization_id=b.organization_id and m.user_id=auth.uid() and m.active
    where b.id=p_branch_id and b.active and (
      m.role='admin' or exists(select 1 from staff_branch_assignments a where a.staff_id=auth.uid() and a.branch_id=b.id)
    )
  );
$$;

alter table public.branches alter column organization_id set default public.current_organization_id();
alter table public.categories alter column organization_id set default public.current_organization_id();
alter table public.products alter column organization_id set default public.current_organization_id();
alter table public.customers alter column organization_id set default public.current_organization_id();
alter table public.suppliers alter column organization_id set default public.current_organization_id();
alter table public.expense_categories alter column organization_id set default public.current_organization_id();
alter table public.system_settings alter column organization_id set default public.current_organization_id();
alter table public.audit_events alter column organization_id set default public.current_organization_id();
alter table public.backup_controls alter column organization_id set default public.current_organization_id();
alter table public.recovery_drills alter column organization_id set default public.current_organization_id();

alter table public.organizations enable row level security;
alter table public.organization_memberships enable row level security;

create policy "members read organizations" on public.organizations for select to authenticated
  using(public.is_organization_member(id));
create policy "members read organization memberships" on public.organization_memberships for select to authenticated
  using(user_id=auth.uid() or public.is_organization_admin(organization_id));
create policy "admins manage organization memberships" on public.organization_memberships for all to authenticated
  using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));

drop policy if exists "staff read own profile" on public.profiles;
drop policy if exists "admins update staff" on public.profiles;
create policy "tenant staff read profiles" on public.profiles for select to authenticated using(
  id=auth.uid() or exists(select 1 from organization_memberships mine join organization_memberships theirs on theirs.organization_id=mine.organization_id
    where mine.user_id=auth.uid() and mine.active and mine.role='admin' and theirs.user_id=profiles.id)
);
create policy "tenant admins update profiles" on public.profiles for update to authenticated using(
  exists(select 1 from organization_memberships mine join organization_memberships theirs on theirs.organization_id=mine.organization_id
    where mine.user_id=auth.uid() and mine.active and mine.role='admin' and theirs.user_id=profiles.id)
) with check(
  exists(select 1 from organization_memberships mine join organization_memberships theirs on theirs.organization_id=mine.organization_id
    where mine.user_id=auth.uid() and mine.active and mine.role='admin' and theirs.user_id=profiles.id)
);

drop policy if exists "staff read assigned branches" on public.branches;
drop policy if exists "admins manage branches" on public.branches;
create policy "tenant staff read branches" on public.branches for select to authenticated using(public.can_access_branch(id));
create policy "tenant admins manage branches" on public.branches for all to authenticated
  using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));

drop policy if exists "staff read own assignments" on public.staff_branch_assignments;
drop policy if exists "admins manage assignments" on public.staff_branch_assignments;
create policy "tenant staff read assignments" on public.staff_branch_assignments for select to authenticated using(
  staff_id=auth.uid() or exists(select 1 from branches b where b.id=branch_id and public.is_organization_admin(b.organization_id))
);
create policy "tenant admins manage assignments" on public.staff_branch_assignments for all to authenticated using(
  exists(select 1 from branches b where b.id=branch_id and public.is_organization_admin(b.organization_id))
) with check(
  exists(select 1 from branches b join organization_memberships m on m.organization_id=b.organization_id
    where b.id=branch_id and m.user_id=staff_id and m.active and public.is_organization_admin(b.organization_id))
);

drop policy if exists "staff read branch products" on public.branch_products;
drop policy if exists "admins manage branch products" on public.branch_products;
create policy "tenant staff read branch products" on public.branch_products for select to authenticated using(public.can_access_branch(branch_id));
create policy "tenant admins manage branch products" on public.branch_products for all to authenticated using(
  exists(select 1 from branches b where b.id=branch_id and public.is_organization_admin(b.organization_id))
) with check(
  exists(select 1 from branches b join products p on p.id=product_id and p.organization_id=b.organization_id
    where b.id=branch_id and public.is_organization_admin(b.organization_id))
);

drop policy if exists "staff read categories" on public.categories;
drop policy if exists "admins manage categories" on public.categories;
create policy "tenant staff read categories" on public.categories for select to authenticated using(public.is_organization_member(organization_id));
create policy "tenant admins manage categories" on public.categories for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));

drop policy if exists "staff read products" on public.products;
drop policy if exists "admins manage products" on public.products;
create policy "tenant staff read products" on public.products for select to authenticated using(public.is_organization_member(organization_id));
create policy "tenant admins manage products" on public.products for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));

drop policy if exists "active staff manage customers" on public.customers;
create policy "tenant staff manage customers" on public.customers for all to authenticated using(public.is_organization_member(organization_id)) with check(public.is_organization_member(organization_id));

drop policy if exists "admins manage suppliers" on public.suppliers;
create policy "tenant admins manage suppliers" on public.suppliers for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));

drop policy if exists "staff read expense categories" on public.expense_categories;
drop policy if exists "admins manage expense categories" on public.expense_categories;
create policy "tenant staff read expense categories" on public.expense_categories for select to authenticated using(public.is_organization_member(organization_id) and (active or public.is_organization_admin(organization_id)));
create policy "tenant admins manage expense categories" on public.expense_categories for all to authenticated using(public.is_organization_admin(organization_id)) with check(public.is_organization_admin(organization_id));

drop policy if exists "admins read system settings" on public.system_settings;
create policy "tenant admins read system settings" on public.system_settings for select to authenticated using(public.is_organization_admin(organization_id));
drop policy if exists "admins read audit events" on public.audit_events;
create policy "tenant admins read audit events" on public.audit_events for select to authenticated using(public.is_organization_admin(organization_id));
drop policy if exists "admins read backup controls" on public.backup_controls;
create policy "tenant admins read backup controls" on public.backup_controls for select to authenticated using(public.is_organization_admin(organization_id));
drop policy if exists "admins read recovery drills" on public.recovery_drills;
create policy "tenant admins read recovery drills" on public.recovery_drills for select to authenticated using(public.is_organization_admin(organization_id));

create or replace function public.enforce_tenant_consistency()
returns trigger language plpgsql set search_path=public as $$
declare v_branch_org uuid;v_related_org uuid;
begin
  if tg_table_name='branch_products' then
    select organization_id into v_branch_org from branches where id=new.branch_id;
    select organization_id into v_related_org from products where id=new.product_id;
  elsif tg_table_name='purchase_orders' then
    select organization_id into v_branch_org from branches where id=new.branch_id;
    select organization_id into v_related_org from suppliers where id=new.supplier_id;
  elsif tg_table_name='expenses' then
    select organization_id into v_branch_org from branches where id=new.branch_id;
    select organization_id into v_related_org from expense_categories where id=new.category_id;
  elsif tg_table_name='stock_transfers' then
    select organization_id into v_branch_org from branches where id=new.from_branch_id;
    select organization_id into v_related_org from branches where id=new.to_branch_id;
  else
    return new;
  end if;
  if v_branch_org is null or v_related_org is null or v_branch_org<>v_related_org then
    raise exception 'Cross-organisation records are not permitted';
  end if;
  return new;
end $$;

create trigger tenant_guard_branch_products before insert or update on public.branch_products for each row execute function public.enforce_tenant_consistency();
create trigger tenant_guard_purchase_orders before insert or update on public.purchase_orders for each row execute function public.enforce_tenant_consistency();
create trigger tenant_guard_expenses before insert or update on public.expenses for each row execute function public.enforce_tenant_consistency();
create trigger tenant_guard_stock_transfers before insert or update on public.stock_transfers for each row execute function public.enforce_tenant_consistency();

create or replace function public.update_backup_controls(p_provider text,p_backup_enabled boolean,p_last_backup_at timestamptz,p_last_verified_at timestamptz,p_evidence_reference text,p_retention_days integer,p_recovery_contact text,p_notes text default null)
returns boolean language plpgsql security definer set search_path=public as $$
declare v_org uuid:=public.current_organization_id();
begin
  if v_org is null or not public.is_organization_admin(v_org) then raise exception 'Administrator access required'; end if;
  if p_backup_enabled and (p_last_backup_at is null or p_last_verified_at is null or nullif(trim(p_evidence_reference),'') is null) then raise exception 'Backup date, verification date and evidence are required when backups are enabled'; end if;
  insert into backup_controls(organization_id,id,provider,backup_enabled,last_backup_at,last_verified_at,verified_by,evidence_reference,retention_days,recovery_contact,notes,updated_at)
  values(v_org,true,nullif(trim(p_provider),''),p_backup_enabled,p_last_backup_at,p_last_verified_at,auth.uid(),nullif(trim(p_evidence_reference),''),p_retention_days,nullif(trim(p_recovery_contact),''),nullif(trim(p_notes),''),now())
  on conflict(organization_id,id) do update set provider=excluded.provider,backup_enabled=excluded.backup_enabled,last_backup_at=excluded.last_backup_at,last_verified_at=excluded.last_verified_at,verified_by=excluded.verified_by,evidence_reference=excluded.evidence_reference,retention_days=excluded.retention_days,recovery_contact=excluded.recovery_contact,notes=excluded.notes,updated_at=now();
  insert into audit_events(organization_id,actor_id,action,entity_type,summary,details) values(v_org,auth.uid(),'verified','backup_controls','Backup evidence updated',jsonb_build_object('provider',p_provider,'backup_enabled',p_backup_enabled,'last_backup_at',p_last_backup_at,'last_verified_at',p_last_verified_at,'retention_days',p_retention_days));
  return true;
end $$;

create or replace function public.record_recovery_drill(p_performed_at timestamptz,p_environment text,p_outcome text,p_duration_minutes integer,p_restored_through timestamptz,p_evidence_reference text,p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;v_org uuid:=public.current_organization_id();
begin
  if v_org is null or not public.is_organization_admin(v_org) then raise exception 'Administrator access required'; end if;
  if p_environment not in ('sandbox','staging','test') or p_outcome not in ('passed','partial','failed') or p_duration_minutes<=0 or nullif(trim(p_evidence_reference),'') is null then raise exception 'Complete valid recovery-drill evidence is required'; end if;
  insert into recovery_drills(organization_id,performed_at,environment,outcome,duration_minutes,restored_through,evidence_reference,notes) values(v_org,p_performed_at,p_environment,p_outcome,p_duration_minutes,p_restored_through,trim(p_evidence_reference),nullif(trim(p_notes),'')) returning id into v_id;
  insert into audit_events(organization_id,actor_id,action,entity_type,entity_id,summary,details) values(v_org,auth.uid(),'recorded','recovery_drills',v_id,'Recovery drill recorded',jsonb_build_object('outcome',p_outcome,'environment',p_environment,'duration_minutes',p_duration_minutes));
  return v_id;
end $$;

create or replace function public.get_audit_log(p_branch_id uuid default null,p_from timestamptz default now()-interval '30 days',p_to timestamptz default now(),p_entity text default null,p_query text default null,p_limit integer default 250)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_result jsonb;v_org uuid:=public.current_organization_id();
begin
  if v_org is null or not public.is_organization_admin(v_org) then raise exception 'Administrator access required'; end if;
  if p_branch_id is not null and not public.can_access_branch(p_branch_id) then raise exception 'Branch access required'; end if;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc),'[]'::jsonb) into v_result from (
    select a.id,a.created_at,a.branch_id,b.code branch_code,b.name branch_name,a.actor_id,coalesce(p.full_name,p.email,'System') actor_name,a.action,a.entity_type,a.entity_id,a.summary,a.details
    from audit_events a left join branches b on b.id=a.branch_id left join profiles p on p.id=a.actor_id
    where a.organization_id=v_org and a.created_at between p_from and p_to and (p_branch_id is null or a.branch_id=p_branch_id) and (p_entity is null or a.entity_type=p_entity)
      and (nullif(trim(p_query),'') is null or a.summary ilike '%'||trim(p_query)||'%' or a.action ilike '%'||trim(p_query)||'%' or coalesce(p.full_name,p.email,'') ilike '%'||trim(p_query)||'%')
    order by a.created_at desc limit least(greatest(coalesce(p_limit,250),1),1000)
  ) x;
  return v_result;
end $$;

create or replace function public.get_backup_readiness()
returns jsonb language plpgsql security definer set search_path=public as $$
declare c backup_controls%rowtype;d recovery_drills%rowtype;v_checks jsonb;v_ready boolean;v_org uuid:=public.current_organization_id();
begin
  if v_org is null or not public.is_organization_admin(v_org) then raise exception 'Administrator access required'; end if;
  select * into c from backup_controls where organization_id=v_org and id=true;
  select * into d from recovery_drills where organization_id=v_org order by performed_at desc limit 1;
  v_ready:=c.backup_enabled and c.last_backup_at>=now()-interval '48 hours' and c.last_verified_at>=now()-interval '30 days' and nullif(trim(c.evidence_reference),'') is not null and coalesce(c.retention_days,0)>=7 and nullif(trim(c.recovery_contact),'') is not null and d.outcome='passed' and d.performed_at>=now()-interval '90 days';
  v_checks:=jsonb_build_array(
    jsonb_build_object('label','Provider backups enabled','passed',coalesce(c.backup_enabled,false)),
    jsonb_build_object('label','Latest backup within 48 hours','passed',c.last_backup_at>=now()-interval '48 hours'),
    jsonb_build_object('label','Evidence verified within 30 days','passed',c.last_verified_at>=now()-interval '30 days' and nullif(trim(c.evidence_reference),'') is not null),
    jsonb_build_object('label','Retention is at least 7 days','passed',coalesce(c.retention_days,0)>=7),
    jsonb_build_object('label','Recovery contact assigned','passed',nullif(trim(c.recovery_contact),'') is not null),
    jsonb_build_object('label','Recovery drill passed within 90 days','passed',d.outcome='passed' and d.performed_at>=now()-interval '90 days'));
  return jsonb_build_object('status',case when v_ready then 'verified' when c.backup_enabled then 'attention' else 'not_configured' end,'controls',to_jsonb(c),'latest_drill',case when d.id is null then null else to_jsonb(d) end,'checks',v_checks,'drills',(select coalesce(jsonb_agg(to_jsonb(r) order by performed_at desc),'[]'::jsonb) from (select * from recovery_drills where organization_id=v_org order by performed_at desc limit 25) r));
end $$;

create or replace function public.create_organization(p_name text,p_slug text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;v_branch uuid;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if exists(select 1 from organization_memberships where user_id=auth.uid()) then raise exception 'This account already belongs to an organisation'; end if;
  if nullif(trim(p_name),'') is null or p_slug !~ '^[a-z0-9]+(?:-[a-z0-9]+)*$' then raise exception 'Valid organisation name and slug required'; end if;
  insert into organizations(name,slug,created_by) values(trim(p_name),p_slug,auth.uid()) returning id into v_id;
  insert into organization_memberships(organization_id,user_id,role) values(v_id,auth.uid(),'admin');
  update profiles set role='admin',active=true,updated_at=now() where id=auth.uid();
  insert into branches(organization_id,code,name) values(v_id,'MAIN','Main Branch') returning id into v_branch;
  insert into staff_branch_assignments(staff_id,branch_id) values(auth.uid(),v_branch);
  insert into expense_categories(organization_id,name) values
    (v_id,'Utilities'),(v_id,'Rent'),(v_id,'Transportation'),(v_id,'Store Supplies'),(v_id,'Repairs & Maintenance'),
    (v_id,'Petty Cash'),(v_id,'Government Fees'),(v_id,'Marketing'),(v_id,'Meals'),(v_id,'Other');
  insert into system_settings(organization_id,setting_key,setting_value) values
    (v_id,'app_version','2.0.0'),(v_id,'migration_version','019');
  insert into backup_controls(organization_id,id) values(v_id,true);
  return v_id;
end $$;

revoke all on function public.create_organization(text,text) from public;
grant execute on function public.create_organization(text,text) to authenticated;
grant select on public.organizations,public.organization_memberships to authenticated;

update public.system_settings set setting_value='2.0.0',updated_at=now() where setting_key='app_version';
update public.system_settings set setting_value='019',updated_at=now() where setting_key='migration_version';

commit;
