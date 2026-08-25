-- Phase 2: secure stock receiving and adjustment functions.
-- Run once in Supabase SQL Editor after retail_schema.sql.

create or replace function public.change_stock(
  p_product_id uuid,
  p_quantity_change numeric,
  p_movement_type text,
  p_notes text default null
) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_new_quantity numeric;
begin
  if auth.uid() is null then raise exception 'Authentication required'; end if;
  if p_quantity_change = 0 then raise exception 'Quantity change cannot be zero'; end if;
  if p_movement_type not in ('purchase','adjustment','return') then
    raise exception 'Invalid stock movement type';
  end if;

  update products
  set quantity_on_hand = quantity_on_hand + p_quantity_change,
      updated_at = now()
  where id = p_product_id
    and quantity_on_hand + p_quantity_change >= 0
  returning quantity_on_hand into v_new_quantity;

  if v_new_quantity is null then
    raise exception 'Product not found or adjustment would create negative stock';
  end if;

  insert into stock_movements(product_id,movement_type,quantity_change,notes)
  values(p_product_id,p_movement_type,p_quantity_change,nullif(trim(p_notes),''));

  return v_new_quantity;
end $$;

revoke all on function public.change_stock(uuid,numeric,text,text) from public;
grant execute on function public.change_stock(uuid,numeric,text,text) to authenticated;

create or replace view public.inventory_movement_history
with (security_invoker = true) as
select
  sm.id,
  sm.created_at,
  sm.product_id,
  p.sku,
  p.name as product_name,
  sm.movement_type,
  sm.quantity_change,
  sm.notes,
  sm.created_by
from public.stock_movements sm
join public.products p on p.id = sm.product_id;

grant select on public.inventory_movement_history to authenticated;
