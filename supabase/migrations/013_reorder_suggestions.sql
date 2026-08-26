-- Phase 13: Automated reorder suggestions, preferred suppliers and draft purchase orders.
-- Run once after 012_stocktake_physical_count.sql.

begin;

-- Convert the original enum to an extensible checked status so draft orders can be added safely.
alter table public.purchase_orders alter column status drop default;
alter table public.purchase_orders alter column status type text using status::text;
drop type public.purchase_order_status;
alter table public.purchase_orders alter column status set default 'ordered';
alter table public.purchase_orders add constraint purchase_orders_status_check
  check(status in ('draft','ordered','partially_received','received','cancelled'));

create table public.product_suppliers (
  product_id uuid not null references public.products(id) on delete cascade,
  supplier_id uuid not null references public.suppliers(id) on delete cascade,
  preferred boolean not null default false,
  supplier_sku text,
  last_unit_cost numeric(12,2) check(last_unit_cost>=0),
  lead_time_days integer not null default 7 check(lead_time_days between 0 and 365),
  updated_at timestamptz not null default now(),
  primary key(product_id,supplier_id)
);

create unique index one_preferred_supplier_per_product on public.product_suppliers(product_id) where preferred;
alter table public.product_suppliers enable row level security;
create policy "admins manage product suppliers" on public.product_suppliers for all to authenticated
  using(public.is_admin()) with check(public.is_admin());

create or replace function public.set_preferred_product_supplier(p_product_id uuid,p_supplier_id uuid,p_unit_cost numeric default null,p_lead_time_days integer default 7)
returns uuid language plpgsql security definer set search_path=public as $$
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if not exists(select 1 from suppliers where id=p_supplier_id and active) then raise exception 'Active supplier required'; end if;
  update product_suppliers set preferred=false,updated_at=now() where product_id=p_product_id and preferred;
  insert into product_suppliers(product_id,supplier_id,preferred,last_unit_cost,lead_time_days)
    values(p_product_id,p_supplier_id,true,p_unit_cost,p_lead_time_days)
    on conflict(product_id,supplier_id) do update set preferred=true,last_unit_cost=coalesce(excluded.last_unit_cost,product_suppliers.last_unit_cost),lead_time_days=excluded.lead_time_days,updated_at=now();
  return p_supplier_id;
end $$;

create or replace function public.get_reorder_suggestions(p_branch_id uuid,p_coverage_days integer default 14)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_result jsonb;
begin
  if not public.is_admin() or not public.can_access_branch(p_branch_id) then raise exception 'Administrator branch access required'; end if;
  if p_coverage_days<1 or p_coverage_days>180 then raise exception 'Coverage days must be between 1 and 180'; end if;
  with sales_velocity as (
    select si.product_id,coalesce(sum(si.quantity),0)/30.0 avg_daily
    from sale_items si join sales s on s.id=si.sale_id
    where s.branch_id=p_branch_id and s.created_at>=now()-interval '30 days' group by si.product_id
  ), open_orders as (
    select poi.product_id,coalesce(sum(poi.ordered_quantity-poi.received_quantity),0) qty
    from purchase_order_items poi join purchase_orders po on po.id=poi.purchase_order_id
    where po.branch_id=p_branch_id and po.status in ('draft','ordered','partially_received') group by poi.product_id
  ), incoming as (
    select sti.product_id,coalesce(sum(sti.quantity),0) qty
    from stock_transfer_items sti join stock_transfers st on st.id=sti.transfer_id
    where st.to_branch_id=p_branch_id and st.status='in_transit' group by sti.product_id
  ), expiring as (
    select product_id,coalesce(sum(quantity_remaining),0) qty from inventory_lots
    where branch_id=p_branch_id and quantity_remaining>0 and expiry_date<=current_date+p_coverage_days group by product_id
  ), suggestion as (
    select p.id product_id,p.name,p.sku,p.barcode,p.cost_price,bp.quantity_on_hand,bp.reorder_level,
      coalesce(sv.avg_daily,0) avg_daily_sales,coalesce(oo.qty,0) on_order,coalesce(inc.qty,0) incoming_transfer,coalesce(ex.qty,0) expiring_soon,
      ps.supplier_id,sup.name supplier_name,coalesce(ps.last_unit_cost,p.cost_price) unit_cost,coalesce(ps.lead_time_days,7) lead_time_days,
      greatest(bp.reorder_level*2,ceil(coalesce(sv.avg_daily,0)*p_coverage_days)) target_stock,
      ceil(greatest(0,greatest(bp.reorder_level*2,coalesce(sv.avg_daily,0)*p_coverage_days)-(bp.quantity_on_hand-coalesce(ex.qty,0))-coalesce(oo.qty,0)-coalesce(inc.qty,0))) suggested_quantity,
      bp.quantity_on_hand<=greatest(1,bp.reorder_level*.25) critical
    from branch_products bp join products p on p.id=bp.product_id
    left join sales_velocity sv on sv.product_id=p.id left join open_orders oo on oo.product_id=p.id
    left join incoming inc on inc.product_id=p.id left join expiring ex on ex.product_id=p.id
    left join product_suppliers ps on ps.product_id=p.id and ps.preferred left join suppliers sup on sup.id=ps.supplier_id
    where bp.branch_id=p_branch_id and bp.active and p.active
  )
  select coalesce(jsonb_agg(to_jsonb(s) order by s.critical desc,s.suggested_quantity desc,s.name),'[]'::jsonb) into v_result
  from suggestion s where s.suggested_quantity>0 or s.critical;
  return v_result;
end $$;

create or replace function public.create_reorder_draft_orders(p_branch_id uuid,p_items jsonb,p_coverage_days integer default 14)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_group record;v_item jsonb;v_po uuid;v_ids jsonb='[]'::jsonb;
begin
  if not public.is_admin() or not public.can_access_branch(p_branch_id) then raise exception 'Administrator branch access required'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Select at least one reorder item'; end if;
  if exists(select 1 from jsonb_array_elements(p_items) i where nullif(i->>'supplier_id','') is null or (i->>'quantity')::numeric<=0) then raise exception 'Every selected item needs a supplier and positive quantity'; end if;
  for v_group in select distinct (i->>'supplier_id')::uuid supplier_id from jsonb_array_elements(p_items) i loop
    if not exists(select 1 from suppliers where id=v_group.supplier_id and active) then raise exception 'Active supplier required'; end if;
    insert into purchase_orders(supplier_id,branch_id,status,notes)
      values(v_group.supplier_id,p_branch_id,'draft',concat('Automated reorder suggestion · ',p_coverage_days,' days coverage')) returning id into v_po;
    for v_item in select * from jsonb_array_elements(p_items) i where (i->>'supplier_id')::uuid=v_group.supplier_id loop
      insert into purchase_order_items(purchase_order_id,product_id,ordered_quantity,unit_cost)
        values(v_po,(v_item->>'product_id')::uuid,(v_item->>'quantity')::numeric,(v_item->>'unit_cost')::numeric);
    end loop;
    v_ids:=v_ids||jsonb_build_array(v_po);
  end loop;
  return v_ids;
end $$;

create or replace function public.confirm_purchase_order(p_purchase_order_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_branch uuid;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select branch_id into v_branch from purchase_orders where id=p_purchase_order_id and status='draft' for update;
  if v_branch is null or not public.can_access_branch(v_branch) then raise exception 'Draft purchase order not found or branch access denied'; end if;
  update purchase_orders set status='ordered',ordered_at=now() where id=p_purchase_order_id;
  return p_purchase_order_id;
end $$;

-- Draft orders must be confirmed before receiving.
create or replace function public.receive_purchase_order(p_purchase_order_id uuid,p_receipts jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_po purchase_orders%rowtype;v_receipt jsonb;v_item purchase_order_items%rowtype;v_qty numeric(12,3);v_lot text;v_expiry date;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select * into v_po from purchase_orders where id=p_purchase_order_id for update;
  if v_po.id is null or not public.can_access_branch(v_po.branch_id) then raise exception 'Purchase order not found or branch access denied'; end if;
  if v_po.status not in ('ordered','partially_received') then raise exception 'Confirm the purchase order before receiving'; end if;
  if p_receipts is null or jsonb_typeof(p_receipts)<>'array' or jsonb_array_length(p_receipts)=0 then raise exception 'Enter at least one received quantity'; end if;
  for v_receipt in select * from jsonb_array_elements(p_receipts) loop
    select * into v_item from purchase_order_items where id=(v_receipt->>'item_id')::uuid and purchase_order_id=p_purchase_order_id for update;
    v_qty:=(v_receipt->>'quantity')::numeric;v_lot:=nullif(trim(v_receipt->>'lot_number'),'');v_expiry:=nullif(v_receipt->>'expiry_date','')::date;
    if v_item.id is null or v_qty<=0 or v_item.received_quantity+v_qty>v_item.ordered_quantity then raise exception 'Received quantity exceeds the outstanding order'; end if;
    update purchase_order_items set received_quantity=received_quantity+v_qty where id=v_item.id;
    update branch_products set quantity_on_hand=quantity_on_hand+v_qty,updated_at=now() where branch_id=v_po.branch_id and product_id=v_item.product_id;
    update products set cost_price=v_item.unit_cost,updated_at=now() where id=v_item.product_id;
    insert into inventory_lots(branch_id,product_id,supplier_id,purchase_order_item_id,lot_number,expiry_date,quantity_received,quantity_remaining,unit_cost)
      values(v_po.branch_id,v_item.product_id,v_po.supplier_id,v_item.id,v_lot,v_expiry,v_qty,v_qty,v_item.unit_cost);
    insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id,notes)
      values(v_po.branch_id,v_item.product_id,'purchase',v_qty,p_purchase_order_id,concat('PO receipt',case when v_lot is not null then ' · Lot '||v_lot else '' end));
  end loop;
  if not exists(select 1 from purchase_order_items where purchase_order_id=p_purchase_order_id and received_quantity<ordered_quantity) then
    update purchase_orders set status='received',completed_at=now() where id=p_purchase_order_id;
  else update purchase_orders set status='partially_received' where id=p_purchase_order_id; end if;
  return p_purchase_order_id;
end $$;

revoke all on function public.set_preferred_product_supplier(uuid,uuid,numeric,integer) from public;
revoke all on function public.get_reorder_suggestions(uuid,integer) from public;
revoke all on function public.create_reorder_draft_orders(uuid,jsonb,integer) from public;
revoke all on function public.confirm_purchase_order(uuid) from public;
grant execute on function public.set_preferred_product_supplier(uuid,uuid,numeric,integer) to authenticated;
grant execute on function public.get_reorder_suggestions(uuid,integer) to authenticated;
grant execute on function public.create_reorder_draft_orders(uuid,jsonb,integer) to authenticated;
grant execute on function public.confirm_purchase_order(uuid) to authenticated;
grant select on public.product_suppliers to authenticated;

commit;
