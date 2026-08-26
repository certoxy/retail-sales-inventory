-- Phase 16: Idempotent synchronization for device-queued offline cash sales.
-- Run once after 015_inventory_disposals.sql.

begin;

alter table public.sales add column offline_transaction_id uuid;
alter table public.sales add column synced_at timestamptz;
create unique index sales_offline_transaction_uidx on public.sales(offline_transaction_id) where offline_transaction_id is not null;

create or replace function public.sync_offline_sale(
  p_offline_transaction_id uuid,p_branch_id uuid,p_shift_id uuid,p_items jsonb,p_created_at timestamptz
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_sale_id uuid;v_receipt bigint;v_subtotal numeric(12,2);v_item jsonb;v_product products%rowtype;v_bp branch_products%rowtype;v_shift cash_shifts%rowtype;v_qty numeric;v_left numeric;v_take numeric;v_lot inventory_lots%rowtype;
begin
  if p_offline_transaction_id is null then raise exception 'Offline transaction identifier required'; end if;
  perform pg_advisory_xact_lock(hashtext(p_offline_transaction_id::text));
  select id,receipt_number into v_sale_id,v_receipt from sales where offline_transaction_id=p_offline_transaction_id;
  if v_sale_id is not null then return jsonb_build_object('sale_id',v_sale_id,'receipt_number',v_receipt,'duplicate',true); end if;
  if not public.is_active_staff() or not public.can_access_branch(p_branch_id) then raise exception 'Branch access required'; end if;
  select * into v_shift from cash_shifts where id=p_shift_id and branch_id=p_branch_id and cashier_id=auth.uid();
  if v_shift.id is null then raise exception 'The original cashier shift is unavailable'; end if;
  if p_created_at<v_shift.opened_at or (v_shift.closed_at is not null and p_created_at>v_shift.closed_at) then raise exception 'Offline sale time is outside the cashier shift'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Sale must contain at least one item'; end if;
  select round(sum((i->>'quantity')::numeric*bp.selling_price),2) into v_subtotal from jsonb_array_elements(p_items) i join branch_products bp on bp.product_id=(i->>'product_id')::uuid and bp.branch_id=p_branch_id and bp.active;
  if v_subtotal is null then raise exception 'One or more products are no longer available'; end if;
  insert into sales(branch_id,shift_id,subtotal,vat_amount,total,payment_method,cashier_id,created_at,offline_transaction_id,synced_at)
    values(p_branch_id,p_shift_id,v_subtotal,round(v_subtotal-(v_subtotal/1.12),2),v_subtotal,'cash',auth.uid(),p_created_at,p_offline_transaction_id,now()) returning id,receipt_number into v_sale_id,v_receipt;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty:=(v_item->>'quantity')::numeric;
    select * into v_product from products where id=(v_item->>'product_id')::uuid and active;
    select * into v_bp from branch_products where branch_id=p_branch_id and product_id=v_product.id and active for update;
    if v_product.id is null or v_bp.product_id is null or v_qty<=0 then raise exception 'Invalid offline sale product'; end if;
    if v_bp.quantity_on_hand<v_qty then raise exception 'Stock conflict for %: only % available',v_product.name,v_bp.quantity_on_hand; end if;
    insert into sale_items(sale_id,product_id,quantity,unit_price) values(v_sale_id,v_product.id,v_qty,v_bp.selling_price);
    update branch_products set quantity_on_hand=quantity_on_hand-v_qty,updated_at=now() where branch_id=p_branch_id and product_id=v_product.id;
    v_left:=v_qty;for v_lot in select * from inventory_lots where branch_id=p_branch_id and product_id=v_product.id and quantity_remaining>0 order by expiry_date asc nulls last,received_at asc for update loop
      v_take:=least(v_left,v_lot.quantity_remaining);update inventory_lots set quantity_remaining=quantity_remaining-v_take where id=v_lot.id;v_left:=v_left-v_take;exit when v_left<=0;
    end loop;
    insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id,notes) values(p_branch_id,v_product.id,'sale',-v_qty,v_sale_id,'Synchronized offline cash sale');
  end loop;
  return jsonb_build_object('sale_id',v_sale_id,'receipt_number',v_receipt,'duplicate',false);
end $$;

revoke all on function public.sync_offline_sale(uuid,uuid,uuid,jsonb,timestamptz) from public;
grant execute on function public.sync_offline_sale(uuid,uuid,uuid,jsonb,timestamptz) to authenticated;

commit;
