-- RetailFlow starter schema. Run once in Supabase SQL Editor.
create extension if not exists pgcrypto;

create table public.categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  created_at timestamptz not null default now()
);

create table public.products (
  id uuid primary key default gen_random_uuid(),
  sku text not null unique,
  barcode text unique,
  name text not null,
  category_id uuid references public.categories(id) on delete set null,
  selling_price numeric(12,2) not null check (selling_price >= 0),
  cost_price numeric(12,2) not null default 0 check (cost_price >= 0),
  quantity_on_hand numeric(12,3) not null default 0,
  reorder_level numeric(12,3) not null default 5,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text,
  phone text,
  created_at timestamptz not null default now()
);

create table public.sales (
  id uuid primary key default gen_random_uuid(),
  receipt_number bigint generated always as identity unique,
  customer_id uuid references public.customers(id) on delete set null,
  subtotal numeric(12,2) not null,
  vat_amount numeric(12,2) not null default 0,
  total numeric(12,2) not null,
  payment_method text not null check (payment_method in ('cash','card','gcash')),
  cashier_id uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now()
);

create table public.sale_items (
  id uuid primary key default gen_random_uuid(),
  sale_id uuid not null references public.sales(id) on delete cascade,
  product_id uuid not null references public.products(id),
  quantity numeric(12,3) not null check (quantity > 0),
  unit_price numeric(12,2) not null check (unit_price >= 0),
  line_total numeric(12,2) generated always as (round(quantity * unit_price, 2)) stored
);

create table public.stock_movements (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references public.products(id),
  movement_type text not null check (movement_type in ('opening','purchase','sale','adjustment','return')),
  quantity_change numeric(12,3) not null check (quantity_change <> 0),
  reference_id uuid,
  notes text,
  created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now()
);

create index products_name_idx on public.products using gin (to_tsvector('simple', name));
create index sales_created_at_idx on public.sales(created_at desc);
create index stock_movements_product_idx on public.stock_movements(product_id, created_at desc);

alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.customers enable row level security;
alter table public.sales enable row level security;
alter table public.sale_items enable row level security;
alter table public.stock_movements enable row level security;

create policy "staff read categories" on public.categories for select to authenticated using (true);
create policy "staff manage categories" on public.categories for all to authenticated using (true) with check (true);
create policy "staff read products" on public.products for select to authenticated using (true);
create policy "staff manage products" on public.products for all to authenticated using (true) with check (true);
create policy "staff manage customers" on public.customers for all to authenticated using (true) with check (true);
create policy "staff read sales" on public.sales for select to authenticated using (true);
create policy "staff read sale items" on public.sale_items for select to authenticated using (true);
create policy "staff read movements" on public.stock_movements for select to authenticated using (true);

create or replace function public.complete_sale(p_items jsonb, p_payment_method text, p_customer_id uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  v_sale_id uuid;
  v_subtotal numeric(12,2);
  v_item jsonb;
  v_product products%rowtype;
  v_qty numeric(12,3);
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_payment_method not in ('cash','card','gcash') then raise exception 'Invalid payment method'; end if;
  if jsonb_array_length(p_items) = 0 then raise exception 'Sale must contain at least one item'; end if;

  select round(sum((i->>'quantity')::numeric * p.selling_price),2) into v_subtotal
  from jsonb_array_elements(p_items) i join products p on p.id=(i->>'product_id')::uuid;

  insert into sales(customer_id,subtotal,vat_amount,total,payment_method)
  values(p_customer_id,v_subtotal,round(v_subtotal-(v_subtotal/1.12),2),v_subtotal,p_payment_method)
  returning id into v_sale_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty := (v_item->>'quantity')::numeric;
    select * into v_product from products where id=(v_item->>'product_id')::uuid for update;
    if v_product.id is null or not v_product.active then raise exception 'Product unavailable'; end if;
    if v_qty <= 0 or v_product.quantity_on_hand < v_qty then raise exception 'Insufficient stock for %', v_product.name; end if;
    insert into sale_items(sale_id,product_id,quantity,unit_price) values(v_sale_id,v_product.id,v_qty,v_product.selling_price);
    update products set quantity_on_hand=quantity_on_hand-v_qty,updated_at=now() where id=v_product.id;
    insert into stock_movements(product_id,movement_type,quantity_change,reference_id) values(v_product.id,'sale',-v_qty,v_sale_id);
  end loop;
  return v_sale_id;
end $$;
revoke all on function public.complete_sale(jsonb,text,uuid) from public;
grant execute on function public.complete_sale(jsonb,text,uuid) to authenticated;

insert into public.categories(name) values ('Grocery'),('Dairy'),('Bakery'),('Household'),('Beverages');
insert into public.products(sku,name,category_id,selling_price,cost_price,quantity_on_hand,reorder_level)
select v.sku,v.name,c.id,v.price,v.cost,v.stock,v.reorder
from (values
 ('GRO-001','Premium Rice 5 kg','Grocery',295,250,24,8),
 ('DAI-014','Fresh Milk 1 L','Dairy',105,82,8,10),
 ('BAK-007','Whole Wheat Bread','Bakery',78,55,15,6),
 ('HOM-022','Laundry Detergent','Household',189,145,5,8),
 ('BEV-031','Ground Coffee 250 g','Beverages',245,190,12,6),
 ('BEV-003','Mineral Water 1 L','Beverages',35,22,42,12)
) as v(sku,name,category,price,cost,stock,reorder)
join public.categories c on c.name=v.category;

insert into public.stock_movements(product_id,movement_type,quantity_change,notes,created_by)
select id,'opening',quantity_on_hand,'Initial sample inventory',auth.uid() from public.products
where auth.uid() is not null;
