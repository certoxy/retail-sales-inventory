-- Phase 5: Multi-branch foundation with branch-specific prices and inventory.
-- Run once after 004_barcode_generation.sql.

create table public.branches (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  address text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.staff_branch_assignments (
  staff_id uuid not null references public.profiles(id) on delete cascade,
  branch_id uuid not null references public.branches(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key(staff_id,branch_id)
);

create table public.branch_products (
  branch_id uuid not null references public.branches(id) on delete cascade,
  product_id uuid not null references public.products(id) on delete cascade,
  selling_price numeric(12,2) not null check(selling_price>=0),
  quantity_on_hand numeric(12,3) not null default 0,
  reorder_level numeric(12,3) not null default 5,
  active boolean not null default true,
  updated_at timestamptz not null default now(),
  primary key(branch_id,product_id)
);

alter table public.sales add column branch_id uuid references public.branches(id);
alter table public.stock_movements add column branch_id uuid references public.branches(id);

do $$
declare v_branch_id uuid;
begin
  insert into branches(code,name,address) values('MAIN','Main Branch','Bohol')
  returning id into v_branch_id;

  insert into staff_branch_assignments(staff_id,branch_id)
  select id,v_branch_id from profiles where active;

  insert into branch_products(branch_id,product_id,selling_price,quantity_on_hand,reorder_level,active)
  select v_branch_id,id,selling_price,quantity_on_hand,reorder_level,active from products;

  update sales set branch_id=v_branch_id where branch_id is null;
  update stock_movements set branch_id=v_branch_id where branch_id is null;
end $$;

alter table public.sales alter column branch_id set not null;
alter table public.stock_movements alter column branch_id set not null;
create index sales_branch_date_idx on public.sales(branch_id,created_at desc);
create index movements_branch_product_idx on public.stock_movements(branch_id,product_id,created_at desc);

create or replace function public.can_access_branch(p_branch_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select public.is_admin() or exists(
    select 1 from staff_branch_assignments
    where staff_id=auth.uid() and branch_id=p_branch_id
  );
$$;

alter table public.branches enable row level security;
alter table public.staff_branch_assignments enable row level security;
alter table public.branch_products enable row level security;

create policy "staff read assigned branches" on public.branches for select to authenticated
  using(active and public.can_access_branch(id));
create policy "admins manage branches" on public.branches for all to authenticated
  using(public.is_admin()) with check(public.is_admin());
create policy "staff read own assignments" on public.staff_branch_assignments for select to authenticated
  using(staff_id=auth.uid() or public.is_admin());
create policy "admins manage assignments" on public.staff_branch_assignments for all to authenticated
  using(public.is_admin()) with check(public.is_admin());
create policy "staff read branch products" on public.branch_products for select to authenticated
  using(public.can_access_branch(branch_id));
create policy "admins manage branch products" on public.branch_products for all to authenticated
  using(public.is_admin()) with check(public.is_admin());

drop policy if exists "staff read permitted sales" on public.sales;
drop policy if exists "staff read permitted sale items" on public.sale_items;
drop policy if exists "admins read movements" on public.stock_movements;
create policy "staff read branch sales" on public.sales for select to authenticated
  using(public.can_access_branch(branch_id) and (cashier_id=auth.uid() or public.is_admin()));
create policy "staff read branch sale items" on public.sale_items for select to authenticated
  using(exists(select 1 from sales s where s.id=sale_id and public.can_access_branch(s.branch_id) and (s.cashier_id=auth.uid() or public.is_admin())));
create policy "admins read branch movements" on public.stock_movements for select to authenticated
  using(public.is_admin() and public.can_access_branch(branch_id));

create or replace view public.inventory_movement_history
with(security_invoker=true) as
select sm.id,sm.created_at,sm.branch_id,b.name as branch_name,sm.product_id,
       p.sku,p.name as product_name,sm.movement_type,sm.quantity_change,
       sm.notes,sm.created_by
from stock_movements sm
join products p on p.id=sm.product_id
join branches b on b.id=sm.branch_id;

revoke execute on function public.complete_sale(jsonb,text,uuid) from authenticated;
revoke execute on function public.change_stock(uuid,numeric,text,text) from authenticated;

create or replace function public.complete_branch_sale(
  p_branch_id uuid,p_items jsonb,p_payment_method text,p_customer_id uuid default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale_id uuid;v_subtotal numeric(12,2);v_item jsonb;v_product products%rowtype;v_branch_product branch_products%rowtype;v_qty numeric(12,3);
begin
  if not public.is_active_staff() or not public.can_access_branch(p_branch_id) then raise exception 'Branch access required'; end if;
  if p_payment_method not in ('cash','card','gcash') then raise exception 'Invalid payment method'; end if;
  if jsonb_array_length(p_items)=0 then raise exception 'Sale must contain at least one item'; end if;
  select round(sum((i->>'quantity')::numeric*bp.selling_price),2) into v_subtotal
  from jsonb_array_elements(p_items) i join branch_products bp
    on bp.product_id=(i->>'product_id')::uuid and bp.branch_id=p_branch_id and bp.active;
  insert into sales(branch_id,customer_id,subtotal,vat_amount,total,payment_method)
  values(p_branch_id,p_customer_id,v_subtotal,round(v_subtotal-(v_subtotal/1.12),2),v_subtotal,p_payment_method)
  returning id into v_sale_id;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty:=(v_item->>'quantity')::numeric;
    select * into v_product from products where id=(v_item->>'product_id')::uuid and active;
    select * into v_branch_product from branch_products
      where branch_id=p_branch_id and product_id=v_product.id and active for update;
    if v_product.id is null or v_branch_product.product_id is null then raise exception 'Product unavailable at this branch'; end if;
    if v_qty<=0 or v_branch_product.quantity_on_hand<v_qty then raise exception 'Insufficient stock for %',v_product.name; end if;
    insert into sale_items(sale_id,product_id,quantity,unit_price)
    values(v_sale_id,v_product.id,v_qty,v_branch_product.selling_price);
    update branch_products set quantity_on_hand=quantity_on_hand-v_qty,updated_at=now()
      where branch_id=p_branch_id and product_id=v_product.id;
    insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id)
    values(p_branch_id,v_product.id,'sale',-v_qty,v_sale_id);
  end loop;
  return v_sale_id;
end $$;

create or replace function public.change_branch_stock(
  p_branch_id uuid,p_product_id uuid,p_quantity_change numeric,p_movement_type text,p_notes text default null
) returns numeric language plpgsql security definer set search_path=public as $$
declare v_new_quantity numeric;
begin
  if not public.is_admin() or not public.can_access_branch(p_branch_id) then raise exception 'Administrator branch access required'; end if;
  if p_quantity_change=0 then raise exception 'Quantity change cannot be zero'; end if;
  if p_movement_type not in ('purchase','adjustment','return') then raise exception 'Invalid stock movement type'; end if;
  update branch_products set quantity_on_hand=quantity_on_hand+p_quantity_change,updated_at=now()
  where branch_id=p_branch_id and product_id=p_product_id and quantity_on_hand+p_quantity_change>=0
  returning quantity_on_hand into v_new_quantity;
  if v_new_quantity is null then raise exception 'Product unavailable or adjustment would create negative stock'; end if;
  insert into stock_movements(branch_id,product_id,movement_type,quantity_change,notes)
  values(p_branch_id,p_product_id,p_movement_type,p_quantity_change,nullif(trim(p_notes),''));
  return v_new_quantity;
end $$;

grant execute on function public.complete_branch_sale(uuid,jsonb,text,uuid) to authenticated;
grant execute on function public.change_branch_stock(uuid,uuid,numeric,text,text) to authenticated;
grant select on public.branches,public.staff_branch_assignments,public.branch_products to authenticated;
