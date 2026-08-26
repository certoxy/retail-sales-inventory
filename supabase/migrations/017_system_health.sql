-- Phase 17: Administrator system-health diagnostics and release metadata.
-- Run once after 016_offline_sales.sql.

begin;

create table public.system_settings (
  setting_key text primary key,
  setting_value text not null,
  updated_at timestamptz not null default now()
);

insert into public.system_settings(setting_key,setting_value) values
  ('app_version','1.9.0'),('migration_version','017')
on conflict(setting_key) do update set setting_value=excluded.setting_value,updated_at=now();

alter table public.system_settings enable row level security;
create policy "admins read system settings" on public.system_settings for select to authenticated using(public.is_admin());

create or replace function public.get_system_health(p_branch_id uuid default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_negative bigint;v_open_shifts bigint;v_pending_returns bigint;v_pending_expenses bigint;v_pending_disposals bigint;v_pending_stocktakes bigint;v_stuck_transfers bigint;v_old_orders bigint;v_recent_sales bigint;v_active_staff bigint;v_last_sync timestamptz;v_version text;v_migration text;v_status text;v_checks jsonb;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_branch_id is not null and not public.can_access_branch(p_branch_id) then raise exception 'Branch access required'; end if;
  select count(*) into v_negative from branch_products where quantity_on_hand<0 and (p_branch_id is null or branch_id=p_branch_id);
  select count(*) into v_open_shifts from cash_shifts where status='open' and (p_branch_id is null or branch_id=p_branch_id);
  select count(*) into v_pending_returns from returns where status='pending' and (p_branch_id is null or branch_id=p_branch_id);
  select count(*) into v_pending_expenses from expenses where status='pending' and (p_branch_id is null or branch_id=p_branch_id);
  select count(*) into v_pending_disposals from inventory_disposals where status='pending' and (p_branch_id is null or branch_id=p_branch_id);
  select count(*) into v_pending_stocktakes from stocktakes where status in ('counting','submitted') and (p_branch_id is null or branch_id=p_branch_id);
  select count(*) into v_stuck_transfers from stock_transfers where status='in_transit' and sent_at<now()-interval '3 days' and (p_branch_id is null or from_branch_id=p_branch_id or to_branch_id=p_branch_id);
  select count(*) into v_old_orders from purchase_orders where status in ('draft','ordered','partially_received') and ordered_at<now()-interval '14 days' and (p_branch_id is null or branch_id=p_branch_id);
  select count(*) into v_recent_sales from sales where created_at>=now()-interval '24 hours' and (p_branch_id is null or branch_id=p_branch_id);
  select count(*) into v_active_staff from profiles where active;
  select max(synced_at) into v_last_sync from sales where offline_transaction_id is not null and (p_branch_id is null or branch_id=p_branch_id);
  select setting_value into v_version from system_settings where setting_key='app_version';
  select setting_value into v_migration from system_settings where setting_key='migration_version';
  v_status:=case when v_negative>0 then 'critical' when v_stuck_transfers+v_old_orders+v_pending_returns+v_pending_expenses+v_pending_disposals>0 then 'attention' else 'healthy' end;
  v_checks:=jsonb_build_array(
    jsonb_build_object('key','inventory','label','Negative inventory','value',v_negative,'status',case when v_negative>0 then 'critical' else 'healthy' end,'detail','Branch product balances below zero'),
    jsonb_build_object('key','transfers','label','Stuck transfers','value',v_stuck_transfers,'status',case when v_stuck_transfers>0 then 'attention' else 'healthy' end,'detail','In transit for more than 3 days'),
    jsonb_build_object('key','orders','label','Aged purchase orders','value',v_old_orders,'status',case when v_old_orders>0 then 'attention' else 'healthy' end,'detail','Open for more than 14 days'),
    jsonb_build_object('key','returns','label','Pending returns','value',v_pending_returns,'status',case when v_pending_returns>0 then 'attention' else 'healthy' end,'detail','Waiting for administrator review'),
    jsonb_build_object('key','expenses','label','Pending expenses','value',v_pending_expenses,'status',case when v_pending_expenses>0 then 'attention' else 'healthy' end,'detail','Waiting for administrator review'),
    jsonb_build_object('key','disposals','label','Pending disposals','value',v_pending_disposals,'status',case when v_pending_disposals>0 then 'attention' else 'healthy' end,'detail','Stock is not deducted until approval'),
    jsonb_build_object('key','stocktakes','label','Active stocktakes','value',v_pending_stocktakes,'status',case when v_pending_stocktakes>0 then 'attention' else 'healthy' end,'detail','Counting or submitted sessions'),
    jsonb_build_object('key','shifts','label','Open cashier shifts','value',v_open_shifts,'status','healthy','detail','Currently active cash drawers')
  );
  return jsonb_build_object('status',v_status,'checked_at',now(),'app_version',coalesce(v_version,'Unknown'),'migration_version',coalesce(v_migration,'Unknown'),
    'recent_sales',v_recent_sales,'active_staff',v_active_staff,'last_offline_sync',v_last_sync,'checks',v_checks);
end $$;

revoke all on function public.get_system_health(uuid) from public;
grant execute on function public.get_system_health(uuid) to authenticated;
grant select on public.system_settings to authenticated;

commit;
