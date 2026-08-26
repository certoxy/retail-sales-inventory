-- Phase 7: Suppliers, purchase orders, partial receiving and optional expiry lots.
-- Run once after 006_stock_transfers.sql.

begin;

create type public.purchase_order_status as enum ('ordered','partially_received','received','cancelled');

create table public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  contact_name text,
  phone text,
  email text,
  address text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  po_number bigint generated always as identity unique,
  supplier_id uuid not null references public.suppliers(id),
  branch_id uuid not null references public.branches(id),
  status public.purchase_order_status not null default 'ordered',
  supplier_reference text,
  notes text,
  ordered_by uuid not null default auth.uid() references auth.users(id),
  ordered_at timestamptz not null default now(),
  completed_at timestamptz
);

create table public.purchase_order_items (
  id uuid primary key default gen_random_uuid(),
  purchase_order_id uuid not null references public.purchase_orders(id) on delete cascade,
  product_id uuid not null references public.products(id),
  ordered_quantity numeric(12,3) not null check(ordered_quantity>0),
  received_quantity numeric(12,3) not null default 0 check(received_quantity>=0),
  unit_cost numeric(12,2) not null check(unit_cost>=0),
  unique(purchase_order_id,product_id),
  check(received_quantity<=ordered_quantity)
);

create table public.inventory_lots (
  id uuid primary key default gen_random_uuid(),
  branch_id uuid not null references public.branches(id),
  product_id uuid not null references public.products(id),
  supplier_id uuid references public.suppliers(id),
  purchase_order_item_id uuid references public.purchase_order_items(id),
  lot_number text,
  expiry_date date,
  quantity_received numeric(12,3) not null check(quantity_received>0),
  quantity_remaining numeric(12,3) not null check(quantity_remaining>=0),
  unit_cost numeric(12,2) not null check(unit_cost>=0),
  received_by uuid not null default auth.uid() references auth.users(id),
  received_at timestamptz not null default now(),
  check(quantity_remaining<=quantity_received)
);

create table public.stock_transfer_item_lots (
  id uuid primary key default gen_random_uuid(),
  transfer_item_id uuid not null references public.stock_transfer_items(id) on delete cascade,
  lot_number text,
  expiry_date date,
  quantity numeric(12,3) not null check(quantity>0),
  unit_cost numeric(12,2) not null check(unit_cost>=0)
);

create index purchase_orders_branch_status_idx on public.purchase_orders(branch_id,status,ordered_at desc);
create index purchase_order_items_po_idx on public.purchase_order_items(purchase_order_id);
create index inventory_lots_branch_expiry_idx on public.inventory_lots(branch_id,expiry_date) where quantity_remaining>0;

alter table public.suppliers enable row level security;
alter table public.purchase_orders enable row level security;
alter table public.purchase_order_items enable row level security;
alter table public.inventory_lots enable row level security;
alter table public.stock_transfer_item_lots enable row level security;

create policy "admins manage suppliers" on public.suppliers for all to authenticated
  using(public.is_admin()) with check(public.is_admin());
create policy "admins read purchase orders" on public.purchase_orders for select to authenticated
  using(public.is_admin() and public.can_access_branch(branch_id));
create policy "admins read purchase order items" on public.purchase_order_items for select to authenticated
  using(exists(select 1 from purchase_orders po where po.id=purchase_order_id and public.is_admin() and public.can_access_branch(po.branch_id)));
create policy "admins read inventory lots" on public.inventory_lots for select to authenticated
  using(public.is_admin() and public.can_access_branch(branch_id));
create policy "admins read transfer lot details" on public.stock_transfer_item_lots for select to authenticated
  using(exists(select 1 from stock_transfer_items sti join stock_transfers st on st.id=sti.transfer_id where sti.id=transfer_item_id and public.is_admin() and (public.can_access_branch(st.from_branch_id) or public.can_access_branch(st.to_branch_id))));

create or replace function public.create_purchase_order(
  p_supplier_id uuid,p_branch_id uuid,p_items jsonb,p_supplier_reference text default null,p_notes text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_po_id uuid;v_item jsonb;v_product_id uuid;v_qty numeric(12,3);v_cost numeric(12,2);
begin
  if not public.is_admin() or not public.can_access_branch(p_branch_id) then raise exception 'Administrator branch access required'; end if;
  if not exists(select 1 from suppliers where id=p_supplier_id and active) then raise exception 'Active supplier required'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Purchase order must contain at least one item'; end if;
  insert into purchase_orders(supplier_id,branch_id,supplier_reference,notes)
  values(p_supplier_id,p_branch_id,nullif(trim(p_supplier_reference),''),nullif(trim(p_notes),'')) returning id into v_po_id;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid;v_qty:=(v_item->>'quantity')::numeric;v_cost:=(v_item->>'unit_cost')::numeric;
    if v_qty<=0 or v_cost<0 then raise exception 'Invalid purchase order quantity or cost'; end if;
    if not exists(select 1 from branch_products where branch_id=p_branch_id and product_id=v_product_id) then raise exception 'Product is not configured at this branch'; end if;
    insert into purchase_order_items(purchase_order_id,product_id,ordered_quantity,unit_cost) values(v_po_id,v_product_id,v_qty,v_cost);
  end loop;
  return v_po_id;
end $$;

-- Preserve expiry lots during branch transfers, automatically selecting earliest expiry first.
create or replace function public.send_stock_transfer(
  p_from_branch_id uuid,p_to_branch_id uuid,p_items jsonb,p_notes text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_transfer_id uuid;v_transfer_item_id uuid;v_item jsonb;v_product_id uuid;v_qty numeric(12,3);v_name text;v_left numeric(12,3);v_take numeric(12,3);v_lot inventory_lots%rowtype;
begin
  if not public.is_admin() or not public.can_access_branch(p_from_branch_id) or not public.can_access_branch(p_to_branch_id) then raise exception 'Administrator branch access required'; end if;
  if p_from_branch_id=p_to_branch_id then raise exception 'Source and destination branches must differ'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Transfer must contain at least one item'; end if;
  insert into stock_transfers(from_branch_id,to_branch_id,notes) values(p_from_branch_id,p_to_branch_id,nullif(trim(p_notes),'')) returning id into v_transfer_id;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid;v_qty:=(v_item->>'quantity')::numeric;
    if v_qty<=0 then raise exception 'Transfer quantities must be positive'; end if;
    select p.name into v_name from products p where p.id=v_product_id;
    update branch_products set quantity_on_hand=quantity_on_hand-v_qty,updated_at=now() where branch_id=p_from_branch_id and product_id=v_product_id and active and quantity_on_hand>=v_qty;
    if not found then raise exception 'Insufficient source stock for %',coalesce(v_name,'product'); end if;
    insert into stock_transfer_items(transfer_id,product_id,quantity) values(v_transfer_id,v_product_id,v_qty) returning id into v_transfer_item_id;
    v_left:=v_qty;
    for v_lot in select * from inventory_lots where branch_id=p_from_branch_id and product_id=v_product_id and quantity_remaining>0 order by expiry_date asc nulls last,received_at asc for update loop
      v_take:=least(v_left,v_lot.quantity_remaining);
      update inventory_lots set quantity_remaining=quantity_remaining-v_take where id=v_lot.id;
      insert into stock_transfer_item_lots(transfer_item_id,lot_number,expiry_date,quantity,unit_cost) values(v_transfer_item_id,v_lot.lot_number,v_lot.expiry_date,v_take,v_lot.unit_cost);
      v_left:=v_left-v_take;exit when v_left<=0;
    end loop;
    insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id,notes) values(p_from_branch_id,v_product_id,'transfer_out',-v_qty,v_transfer_id,'Transfer sent');
  end loop;
  return v_transfer_id;
end $$;

create or replace function public.receive_stock_transfer(p_transfer_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_transfer stock_transfers%rowtype;v_item stock_transfer_items%rowtype;v_transfer_lot stock_transfer_item_lots%rowtype;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select * into v_transfer from stock_transfers where id=p_transfer_id for update;
  if v_transfer.id is null then raise exception 'Transfer not found'; end if;
  if not public.can_access_branch(v_transfer.to_branch_id) then raise exception 'Destination branch access required'; end if;
  if v_transfer.status<>'in_transit' then raise exception 'Transfer has already been received'; end if;
  for v_item in select * from stock_transfer_items where transfer_id=p_transfer_id loop
    update branch_products set quantity_on_hand=quantity_on_hand+v_item.quantity,updated_at=now() where branch_id=v_transfer.to_branch_id and product_id=v_item.product_id;
    if not found then raise exception 'Destination product setup is missing'; end if;
    for v_transfer_lot in select * from stock_transfer_item_lots where transfer_item_id=v_item.id loop
      insert into inventory_lots(branch_id,product_id,lot_number,expiry_date,quantity_received,quantity_remaining,unit_cost)
      values(v_transfer.to_branch_id,v_item.product_id,v_transfer_lot.lot_number,v_transfer_lot.expiry_date,v_transfer_lot.quantity,v_transfer_lot.quantity,v_transfer_lot.unit_cost);
    end loop;
    insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id,notes) values(v_transfer.to_branch_id,v_item.product_id,'transfer_in',v_item.quantity,p_transfer_id,'Transfer received');
  end loop;
  update stock_transfers set status='received',received_by=auth.uid(),received_at=now() where id=p_transfer_id;
  return p_transfer_id;
end $$;

create or replace function public.receive_purchase_order(p_purchase_order_id uuid,p_receipts jsonb)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_po purchase_orders%rowtype;v_receipt jsonb;v_item purchase_order_items%rowtype;v_qty numeric(12,3);v_lot text;v_expiry date;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select * into v_po from purchase_orders where id=p_purchase_order_id for update;
  if v_po.id is null or not public.can_access_branch(v_po.branch_id) then raise exception 'Purchase order not found or branch access denied'; end if;
  if v_po.status in ('received','cancelled') then raise exception 'Purchase order cannot be received'; end if;
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
  else
    update purchase_orders set status='partially_received' where id=p_purchase_order_id;
  end if;
  return p_purchase_order_id;
end $$;

-- Keep tracked lot balances aligned with checkout using first-expiry-first-out.
create or replace function public.complete_branch_sale(
  p_branch_id uuid,p_items jsonb,p_payment_method text,p_customer_id uuid default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale_id uuid;v_subtotal numeric(12,2);v_item jsonb;v_product products%rowtype;v_branch_product branch_products%rowtype;v_qty numeric(12,3);v_left numeric(12,3);v_take numeric(12,3);v_lot inventory_lots%rowtype;
begin
  if not public.is_active_staff() or not public.can_access_branch(p_branch_id) then raise exception 'Branch access required'; end if;
  if p_payment_method not in ('cash','card','gcash') then raise exception 'Invalid payment method'; end if;
  if jsonb_array_length(p_items)=0 then raise exception 'Sale must contain at least one item'; end if;
  select round(sum((i->>'quantity')::numeric*bp.selling_price),2) into v_subtotal
  from jsonb_array_elements(p_items) i join branch_products bp on bp.product_id=(i->>'product_id')::uuid and bp.branch_id=p_branch_id and bp.active;
  insert into sales(branch_id,customer_id,subtotal,vat_amount,total,payment_method)
  values(p_branch_id,p_customer_id,v_subtotal,round(v_subtotal-(v_subtotal/1.12),2),v_subtotal,p_payment_method) returning id into v_sale_id;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty:=(v_item->>'quantity')::numeric;
    select * into v_product from products where id=(v_item->>'product_id')::uuid and active;
    select * into v_branch_product from branch_products where branch_id=p_branch_id and product_id=v_product.id and active for update;
    if v_product.id is null or v_branch_product.product_id is null then raise exception 'Product unavailable at this branch'; end if;
    if v_qty<=0 or v_branch_product.quantity_on_hand<v_qty then raise exception 'Insufficient stock for %',v_product.name; end if;
    insert into sale_items(sale_id,product_id,quantity,unit_price) values(v_sale_id,v_product.id,v_qty,v_branch_product.selling_price);
    update branch_products set quantity_on_hand=quantity_on_hand-v_qty,updated_at=now() where branch_id=p_branch_id and product_id=v_product.id;
    v_left:=v_qty;
    for v_lot in select * from inventory_lots where branch_id=p_branch_id and product_id=v_product.id and quantity_remaining>0 order by expiry_date asc nulls last,received_at asc for update loop
      v_take:=least(v_left,v_lot.quantity_remaining);
      update inventory_lots set quantity_remaining=quantity_remaining-v_take where id=v_lot.id;
      v_left:=v_left-v_take;
      exit when v_left<=0;
    end loop;
    insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id) values(p_branch_id,v_product.id,'sale',-v_qty,v_sale_id);
  end loop;
  return v_sale_id;
end $$;

revoke all on function public.create_purchase_order(uuid,uuid,jsonb,text,text) from public;
revoke all on function public.receive_purchase_order(uuid,jsonb) from public;
grant execute on function public.create_purchase_order(uuid,uuid,jsonb,text,text) to authenticated;
grant execute on function public.receive_purchase_order(uuid,jsonb) to authenticated;
grant execute on function public.complete_branch_sale(uuid,jsonb,text,uuid) to authenticated;
grant execute on function public.send_stock_transfer(uuid,uuid,jsonb,text) to authenticated;
grant execute on function public.receive_stock_transfer(uuid) to authenticated;
grant select on public.suppliers,public.purchase_orders,public.purchase_order_items,public.inventory_lots,public.stock_transfer_item_lots to authenticated;

commit;
