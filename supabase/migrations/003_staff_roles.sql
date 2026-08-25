-- Phase 3: Admin and cashier authorization.
-- Run once after 002_inventory_management.sql.

create type public.staff_role as enum ('admin', 'cashier');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text,
  role public.staff_role not null default 'cashier',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Existing users become administrators. New users default to cashier.
insert into public.profiles(id,email,role)
select id,email,'admin'::public.staff_role from auth.users
on conflict (id) do nothing;

create or replace function public.create_staff_profile()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into profiles(id,email,full_name,role)
  values(new.id,new.email,new.raw_user_meta_data->>'full_name','cashier');
  return new;
end $$;

create trigger create_staff_profile_after_signup
after insert on auth.users for each row execute function public.create_staff_profile();

create or replace function public.is_active_staff()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from profiles where id=auth.uid() and active);
$$;

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from profiles where id=auth.uid() and active and role='admin');
$$;

alter table public.profiles enable row level security;
create policy "staff read own profile" on public.profiles for select to authenticated
  using (id=auth.uid() or public.is_admin());
create policy "admins update staff" on public.profiles for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "staff manage categories" on public.categories;
drop policy if exists "staff manage products" on public.products;
drop policy if exists "staff manage customers" on public.customers;
drop policy if exists "staff read sales" on public.sales;
drop policy if exists "staff read sale items" on public.sale_items;
drop policy if exists "staff read movements" on public.stock_movements;

create policy "admins manage categories" on public.categories for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "admins manage products" on public.products for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
create policy "active staff manage customers" on public.customers for all to authenticated
  using (public.is_active_staff()) with check (public.is_active_staff());
create policy "staff read permitted sales" on public.sales for select to authenticated
  using (cashier_id=auth.uid() or public.is_admin());
create policy "staff read permitted sale items" on public.sale_items for select to authenticated
  using (exists(select 1 from sales s where s.id=sale_id and (s.cashier_id=auth.uid() or public.is_admin())));
create policy "admins read movements" on public.stock_movements for select to authenticated
  using (public.is_admin());

create or replace function public.change_stock(
  p_product_id uuid, p_quantity_change numeric, p_movement_type text, p_notes text default null
) returns numeric language plpgsql security definer set search_path=public as $$
declare v_new_quantity numeric;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  if p_quantity_change=0 then raise exception 'Quantity change cannot be zero'; end if;
  if p_movement_type not in ('purchase','adjustment','return') then raise exception 'Invalid stock movement type'; end if;
  update products set quantity_on_hand=quantity_on_hand+p_quantity_change,updated_at=now()
  where id=p_product_id and quantity_on_hand+p_quantity_change>=0
  returning quantity_on_hand into v_new_quantity;
  if v_new_quantity is null then raise exception 'Product not found or adjustment would create negative stock'; end if;
  insert into stock_movements(product_id,movement_type,quantity_change,notes)
  values(p_product_id,p_movement_type,p_quantity_change,nullif(trim(p_notes),''));
  return v_new_quantity;
end $$;

create or replace function public.complete_sale(p_items jsonb,p_payment_method text,p_customer_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale_id uuid; v_subtotal numeric(12,2); v_item jsonb; v_product products%rowtype; v_qty numeric(12,3);
begin
  if not public.is_active_staff() then raise exception 'Active staff access required'; end if;
  if p_payment_method not in ('cash','card','gcash') then raise exception 'Invalid payment method'; end if;
  if jsonb_array_length(p_items)=0 then raise exception 'Sale must contain at least one item'; end if;
  select round(sum((i->>'quantity')::numeric*p.selling_price),2) into v_subtotal
  from jsonb_array_elements(p_items) i join products p on p.id=(i->>'product_id')::uuid;
  insert into sales(customer_id,subtotal,vat_amount,total,payment_method)
  values(p_customer_id,v_subtotal,round(v_subtotal-(v_subtotal/1.12),2),v_subtotal,p_payment_method)
  returning id into v_sale_id;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty:=(v_item->>'quantity')::numeric;
    select * into v_product from products where id=(v_item->>'product_id')::uuid for update;
    if v_product.id is null or not v_product.active then raise exception 'Product unavailable'; end if;
    if v_qty<=0 or v_product.quantity_on_hand<v_qty then raise exception 'Insufficient stock for %',v_product.name; end if;
    insert into sale_items(sale_id,product_id,quantity,unit_price) values(v_sale_id,v_product.id,v_qty,v_product.selling_price);
    update products set quantity_on_hand=quantity_on_hand-v_qty,updated_at=now() where id=v_product.id;
    insert into stock_movements(product_id,movement_type,quantity_change,reference_id) values(v_product.id,'sale',-v_qty,v_sale_id);
  end loop;
  return v_sale_id;
end $$;

grant select on public.profiles to authenticated;
grant update(role,active,full_name) on public.profiles to authenticated;
