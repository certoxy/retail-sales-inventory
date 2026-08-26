-- Phase 9: Permission-aware receipt retrieval and reprinting.
-- Run once after 008_sales_dashboard.sql.

begin;

create or replace function public.get_sale_receipt(p_sale_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_sale sales%rowtype;v_branch branches%rowtype;v_cashier text;v_items jsonb;
begin
  if not public.is_active_staff() then raise exception 'Active staff access required'; end if;
  select * into v_sale from sales where id=p_sale_id;
  if v_sale.id is null then raise exception 'Sale not found'; end if;
  if not public.can_access_branch(v_sale.branch_id) or (not public.is_admin() and v_sale.cashier_id<>auth.uid()) then
    raise exception 'Receipt access denied';
  end if;
  select * into v_branch from branches where id=v_sale.branch_id;
  select coalesce(nullif(full_name,''),email) into v_cashier from profiles where id=v_sale.cashier_id;
  select coalesce(jsonb_agg(jsonb_build_object('name',p.name,'sku',p.sku,'quantity',si.quantity,'unit_price',si.unit_price,'line_total',si.line_total) order by si.id),'[]'::jsonb)
    into v_items from sale_items si join products p on p.id=si.product_id where si.sale_id=p_sale_id;
  return jsonb_build_object(
    'id',v_sale.id,'receipt_number',v_sale.receipt_number,'created_at',v_sale.created_at,
    'branch_name',v_branch.name,'branch_code',v_branch.code,'branch_address',v_branch.address,
    'cashier',coalesce(v_cashier,'Staff'),'payment_method',v_sale.payment_method,
    'subtotal',v_sale.subtotal,'vat_amount',v_sale.vat_amount,'total',v_sale.total,'items',v_items
  );
end $$;

revoke all on function public.get_sale_receipt(uuid) from public;
grant execute on function public.get_sale_receipt(uuid) to authenticated;

commit;
