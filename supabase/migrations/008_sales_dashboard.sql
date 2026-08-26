-- Phase 8: Secure sales and operations dashboard aggregates.
-- Run once after 007_suppliers_purchase_orders_expiry.sql.

begin;

create or replace function public.get_sales_dashboard(
  p_branch_id uuid,p_from date,p_to date
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_admin boolean:=public.is_admin();
  v_sales numeric(14,2);v_transactions bigint;v_average numeric(14,2);v_profit numeric(14,2);
  v_payment jsonb;v_top jsonb;v_daily jsonb;v_branches jsonb;
  v_low bigint;v_expiring bigint;v_expired bigint;v_open_po bigint;v_transit bigint;
begin
  if not public.is_active_staff() then raise exception 'Active staff access required'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'Invalid date range'; end if;
  if p_branch_id is not null and not public.can_access_branch(p_branch_id) then raise exception 'Branch access required'; end if;
  if not v_admin and p_branch_id is null then raise exception 'Cashiers must select an assigned branch'; end if;

  select coalesce(sum(s.total),0),count(*),coalesce(avg(s.total),0),
         coalesce(sum(si.quantity*(si.unit_price-p.cost_price)),0)
  into v_sales,v_transactions,v_average,v_profit
  from sales s left join sale_items si on si.sale_id=s.id left join products p on p.id=si.product_id
  where s.created_at>=p_from::timestamptz and s.created_at<(p_to+1)::timestamptz
    and (p_branch_id is null or s.branch_id=p_branch_id) and (v_admin or s.cashier_id=auth.uid());

  -- The sale join repeats totals per item, so calculate headline sales separately.
  select coalesce(sum(s.total),0),count(*),coalesce(avg(s.total),0) into v_sales,v_transactions,v_average
  from sales s where s.created_at>=p_from::timestamptz and s.created_at<(p_to+1)::timestamptz
    and (p_branch_id is null or s.branch_id=p_branch_id) and (v_admin or s.cashier_id=auth.uid());

  select coalesce(jsonb_agg(jsonb_build_object('method',x.payment_method,'amount',x.amount,'transactions',x.transactions) order by x.amount desc),'[]'::jsonb) into v_payment
  from (select s.payment_method,sum(s.total) amount,count(*) transactions from sales s
    where s.created_at>=p_from::timestamptz and s.created_at<(p_to+1)::timestamptz and (p_branch_id is null or s.branch_id=p_branch_id) and (v_admin or s.cashier_id=auth.uid()) group by s.payment_method) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.revenue desc),'[]'::jsonb) into v_top from (
    select p.name,p.sku,sum(si.quantity) quantity,sum(si.line_total) revenue
    from sales s join sale_items si on si.sale_id=s.id join products p on p.id=si.product_id
    where s.created_at>=p_from::timestamptz and s.created_at<(p_to+1)::timestamptz and (p_branch_id is null or s.branch_id=p_branch_id) and (v_admin or s.cashier_id=auth.uid())
    group by p.id,p.name,p.sku order by revenue desc limit 10) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.sale_date),'[]'::jsonb) into v_daily from (
    select s.created_at::date sale_date,sum(s.total) amount,count(*) transactions from sales s
    where s.created_at>=p_from::timestamptz and s.created_at<(p_to+1)::timestamptz and (p_branch_id is null or s.branch_id=p_branch_id) and (v_admin or s.cashier_id=auth.uid())
    group by s.created_at::date) x;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.amount desc),'[]'::jsonb) into v_branches from (
    select b.id,b.code,b.name,sum(s.total) amount,count(*) transactions from sales s join branches b on b.id=s.branch_id
    where s.created_at>=p_from::timestamptz and s.created_at<(p_to+1)::timestamptz and (p_branch_id is null or s.branch_id=p_branch_id) and (v_admin or s.cashier_id=auth.uid())
    group by b.id,b.code,b.name) x;

  select count(*) into v_low from branch_products bp where bp.active and bp.quantity_on_hand<=bp.reorder_level and (p_branch_id is null or bp.branch_id=p_branch_id) and public.can_access_branch(bp.branch_id);
  select count(*) filter(where expiry_date between current_date and current_date+30),count(*) filter(where expiry_date<current_date)
    into v_expiring,v_expired from inventory_lots l where l.quantity_remaining>0 and (p_branch_id is null or l.branch_id=p_branch_id) and public.can_access_branch(l.branch_id);
  select count(*) into v_open_po from purchase_orders po where po.status in ('ordered','partially_received') and (p_branch_id is null or po.branch_id=p_branch_id) and public.can_access_branch(po.branch_id);
  select count(*) into v_transit from stock_transfers st where st.status='in_transit' and (p_branch_id is null or st.from_branch_id=p_branch_id or st.to_branch_id=p_branch_id) and (public.can_access_branch(st.from_branch_id) or public.can_access_branch(st.to_branch_id));

  return jsonb_build_object('sales',v_sales,'transactions',v_transactions,'average_sale',v_average,'estimated_profit',case when v_admin then v_profit else null end,'show_profit',v_admin,
    'payment_methods',v_payment,'top_products',v_top,'daily_sales',v_daily,'branch_sales',v_branches,'low_stock',v_low,'expiring',v_expiring,'expired',v_expired,'open_purchase_orders',v_open_po,'transfers_in_transit',v_transit);
end $$;

revoke all on function public.get_sales_dashboard(uuid,date,date) from public;
grant execute on function public.get_sales_dashboard(uuid,date,date) to authenticated;

commit;
