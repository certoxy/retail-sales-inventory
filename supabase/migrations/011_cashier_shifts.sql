-- Phase 11: Cashier shifts, cash movements and closing reconciliation.
-- Run once after 010_returns_refunds.sql.

begin;

create type public.cash_shift_status as enum ('open','closed','reviewed');
create type public.cash_movement_type as enum ('cash_in','cash_out');

create table public.cash_shifts (
  id uuid primary key default gen_random_uuid(),
  shift_number bigint generated always as identity unique,
  branch_id uuid not null references public.branches(id),
  cashier_id uuid not null default auth.uid() references auth.users(id),
  status public.cash_shift_status not null default 'open',
  opening_cash numeric(12,2) not null check(opening_cash>=0),
  expected_cash numeric(12,2),
  actual_closing_cash numeric(12,2),
  cash_difference numeric(12,2),
  closing_notes text,
  discrepancy_reason text,
  opened_at timestamptz not null default now(),
  closed_at timestamptz,
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_notes text
);

create unique index one_open_shift_per_cashier on public.cash_shifts(cashier_id) where status='open';
create index cash_shifts_branch_date_idx on public.cash_shifts(branch_id,opened_at desc);

create table public.cash_movements (
  id uuid primary key default gen_random_uuid(),
  shift_id uuid not null references public.cash_shifts(id),
  movement_type public.cash_movement_type not null,
  amount numeric(12,2) not null check(amount>0),
  reason text not null,
  created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now()
);

alter table public.sales add column shift_id uuid references public.cash_shifts(id);
alter table public.returns add column refund_shift_id uuid references public.cash_shifts(id);

alter table public.cash_shifts enable row level security;
alter table public.cash_movements enable row level security;
create policy "staff read permitted shifts" on public.cash_shifts for select to authenticated
  using(public.can_access_branch(branch_id) and (cashier_id=auth.uid() or public.is_admin()));
create policy "staff read permitted cash movements" on public.cash_movements for select to authenticated
  using(exists(select 1 from cash_shifts cs where cs.id=shift_id and public.can_access_branch(cs.branch_id) and (cs.cashier_id=auth.uid() or public.is_admin())));

create or replace function public.open_cash_shift(p_branch_id uuid,p_opening_cash numeric)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if not public.is_active_staff() or not public.can_access_branch(p_branch_id) then raise exception 'Branch access required'; end if;
  if p_opening_cash<0 then raise exception 'Opening cash cannot be negative'; end if;
  if exists(select 1 from cash_shifts where cashier_id=auth.uid() and status='open') then raise exception 'You already have an open shift'; end if;
  insert into cash_shifts(branch_id,cashier_id,opening_cash) values(p_branch_id,auth.uid(),p_opening_cash) returning id into v_id;
  return v_id;
end $$;

create or replace function public.add_cash_movement(p_shift_id uuid,p_movement_type public.cash_movement_type,p_amount numeric,p_reason text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_shift cash_shifts%rowtype;v_id uuid;
begin
  select * into v_shift from cash_shifts where id=p_shift_id for update;
  if v_shift.id is null or v_shift.cashier_id<>auth.uid() or v_shift.status<>'open' then raise exception 'Your active shift is required'; end if;
  if p_amount<=0 or nullif(trim(p_reason),'') is null then raise exception 'Positive amount and reason required'; end if;
  insert into cash_movements(shift_id,movement_type,amount,reason) values(p_shift_id,p_movement_type,p_amount,trim(p_reason)) returning id into v_id;
  return v_id;
end $$;

create or replace function public.get_shift_summary(p_shift_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_shift cash_shifts%rowtype;v_cash_sales numeric(12,2);v_card numeric(12,2);v_gcash numeric(12,2);v_refunds numeric(12,2);v_in numeric(12,2);v_out numeric(12,2);v_count bigint;v_cashier text;
begin
  select * into v_shift from cash_shifts where id=p_shift_id;
  if v_shift.id is null or not public.can_access_branch(v_shift.branch_id) or (v_shift.cashier_id<>auth.uid() and not public.is_admin()) then raise exception 'Shift access denied'; end if;
  select coalesce(sum(total) filter(where payment_method='cash'),0),coalesce(sum(total) filter(where payment_method='card'),0),coalesce(sum(total) filter(where payment_method='gcash'),0),count(*)
    into v_cash_sales,v_card,v_gcash,v_count from sales where shift_id=p_shift_id;
  select coalesce(sum(r.total_amount),0) into v_refunds from returns r join sales s on s.id=r.sale_id
    where r.refund_shift_id=p_shift_id and r.status='approved' and r.outcome='refund' and (r.refund_method='cash' or (r.refund_method='original' and s.payment_method='cash'));
  select coalesce(sum(amount) filter(where movement_type='cash_in'),0),coalesce(sum(amount) filter(where movement_type='cash_out'),0) into v_in,v_out from cash_movements where shift_id=p_shift_id;
  select coalesce(nullif(full_name,''),email) into v_cashier from profiles where id=v_shift.cashier_id;
  return jsonb_build_object('id',v_shift.id,'shift_number',v_shift.shift_number,'branch_id',v_shift.branch_id,'cashier',coalesce(v_cashier,'Staff'),'status',v_shift.status,
    'opening_cash',v_shift.opening_cash,'cash_sales',v_cash_sales,'card_sales',v_card,'gcash_sales',v_gcash,'transactions',v_count,'cash_refunds',v_refunds,'cash_in',v_in,'cash_out',v_out,
    'calculated_expected',v_shift.opening_cash+v_cash_sales-v_refunds+v_in-v_out,'expected_cash',v_shift.expected_cash,'actual_closing_cash',v_shift.actual_closing_cash,
    'cash_difference',v_shift.cash_difference,'closing_notes',v_shift.closing_notes,'discrepancy_reason',v_shift.discrepancy_reason,'opened_at',v_shift.opened_at,'closed_at',v_shift.closed_at,
    'reviewed_at',v_shift.reviewed_at,'review_notes',v_shift.review_notes);
end $$;

create or replace function public.close_cash_shift(p_shift_id uuid,p_actual_cash numeric,p_closing_notes text default null,p_discrepancy_reason text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_shift cash_shifts%rowtype;v_summary jsonb;v_expected numeric(12,2);v_difference numeric(12,2);
begin
  select * into v_shift from cash_shifts where id=p_shift_id for update;
  if v_shift.id is null or v_shift.cashier_id<>auth.uid() or v_shift.status<>'open' then raise exception 'Your active shift is required'; end if;
  if p_actual_cash<0 then raise exception 'Counted cash cannot be negative'; end if;
  v_summary:=public.get_shift_summary(p_shift_id);v_expected:=(v_summary->>'calculated_expected')::numeric;v_difference:=round(p_actual_cash-v_expected,2);
  if abs(v_difference)>=0.01 and nullif(trim(p_discrepancy_reason),'') is null then raise exception 'Explain the cash difference before closing'; end if;
  update cash_shifts set status='closed',expected_cash=v_expected,actual_closing_cash=p_actual_cash,cash_difference=v_difference,
    closing_notes=nullif(trim(p_closing_notes),''),discrepancy_reason=nullif(trim(p_discrepancy_reason),''),closed_at=now() where id=p_shift_id;
  return p_shift_id;
end $$;

create or replace function public.review_cash_shift(p_shift_id uuid,p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_shift cash_shifts%rowtype;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select * into v_shift from cash_shifts where id=p_shift_id for update;
  if v_shift.id is null or not public.can_access_branch(v_shift.branch_id) or v_shift.status<>'closed' then raise exception 'Closed shift required'; end if;
  update cash_shifts set status='reviewed',reviewed_by=auth.uid(),reviewed_at=now(),review_notes=nullif(trim(p_notes),'') where id=p_shift_id;
  return p_shift_id;
end $$;

-- Require and link the cashier's active branch shift during checkout.
create or replace function public.complete_branch_sale(
  p_branch_id uuid,p_items jsonb,p_payment_method text,p_customer_id uuid default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale_id uuid;v_shift_id uuid;v_subtotal numeric(12,2);v_item jsonb;v_product products%rowtype;v_branch_product branch_products%rowtype;v_qty numeric(12,3);v_left numeric(12,3);v_take numeric(12,3);v_lot inventory_lots%rowtype;
begin
  if not public.is_active_staff() or not public.can_access_branch(p_branch_id) then raise exception 'Branch access required'; end if;
  select id into v_shift_id from cash_shifts where cashier_id=auth.uid() and branch_id=p_branch_id and status='open';
  if v_shift_id is null then raise exception 'Open a cashier shift before completing sales'; end if;
  if p_payment_method not in ('cash','card','gcash') then raise exception 'Invalid payment method'; end if;
  if jsonb_array_length(p_items)=0 then raise exception 'Sale must contain at least one item'; end if;
  select round(sum((i->>'quantity')::numeric*bp.selling_price),2) into v_subtotal from jsonb_array_elements(p_items) i join branch_products bp on bp.product_id=(i->>'product_id')::uuid and bp.branch_id=p_branch_id and bp.active;
  insert into sales(branch_id,shift_id,customer_id,subtotal,vat_amount,total,payment_method) values(p_branch_id,v_shift_id,p_customer_id,v_subtotal,round(v_subtotal-(v_subtotal/1.12),2),v_subtotal,p_payment_method) returning id into v_sale_id;
  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty:=(v_item->>'quantity')::numeric;select * into v_product from products where id=(v_item->>'product_id')::uuid and active;
    select * into v_branch_product from branch_products where branch_id=p_branch_id and product_id=v_product.id and active for update;
    if v_product.id is null or v_branch_product.product_id is null then raise exception 'Product unavailable at this branch'; end if;
    if v_qty<=0 or v_branch_product.quantity_on_hand<v_qty then raise exception 'Insufficient stock for %',v_product.name; end if;
    insert into sale_items(sale_id,product_id,quantity,unit_price) values(v_sale_id,v_product.id,v_qty,v_branch_product.selling_price);
    update branch_products set quantity_on_hand=quantity_on_hand-v_qty,updated_at=now() where branch_id=p_branch_id and product_id=v_product.id;
    v_left:=v_qty;for v_lot in select * from inventory_lots where branch_id=p_branch_id and product_id=v_product.id and quantity_remaining>0 order by expiry_date asc nulls last,received_at asc for update loop
      v_take:=least(v_left,v_lot.quantity_remaining);update inventory_lots set quantity_remaining=quantity_remaining-v_take where id=v_lot.id;v_left:=v_left-v_take;exit when v_left<=0;
    end loop;
    insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id) values(p_branch_id,v_product.id,'sale',-v_qty,v_sale_id);
  end loop;
  return v_sale_id;
end $$;

-- Cash refunds must be approved from an active shift so reconciliation captures the payout.
create or replace function public.decide_return(p_return_id uuid,p_approve boolean,p_decision_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_return returns%rowtype;v_item return_items%rowtype;v_refund_shift uuid;v_original_payment text;
begin
  if not public.is_admin() then raise exception 'Administrator approval required'; end if;
  select * into v_return from returns where id=p_return_id for update;
  if v_return.id is null or not public.can_access_branch(v_return.branch_id) or v_return.status<>'pending' then raise exception 'Pending return not found or branch access denied'; end if;
  if p_approve and v_return.outcome='refund' then
    select payment_method into v_original_payment from sales where id=v_return.sale_id;
    if v_return.refund_method='cash' or (v_return.refund_method='original' and v_original_payment='cash') then
      select id into v_refund_shift from cash_shifts where cashier_id=auth.uid() and branch_id=v_return.branch_id and status='open';
      if v_refund_shift is null then raise exception 'Open a cashier shift before approving a cash refund'; end if;
    end if;
  end if;
  if p_approve then for v_item in select * from return_items where return_id=p_return_id loop
    if v_item.disposition='restock' then
      update branch_products set quantity_on_hand=quantity_on_hand+v_item.quantity,updated_at=now() where branch_id=v_return.branch_id and product_id=v_item.product_id;
      if not found then raise exception 'Branch product setup is missing'; end if;
      insert into inventory_lots(branch_id,product_id,quantity_received,quantity_remaining,unit_cost) select v_return.branch_id,v_item.product_id,v_item.quantity,v_item.quantity,p.cost_price from products p where p.id=v_item.product_id;
      insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id,notes) values(v_return.branch_id,v_item.product_id,'return',v_item.quantity,p_return_id,'Approved customer return');
    end if;
  end loop;end if;
  update returns set status=case when p_approve then 'approved'::return_status else 'rejected'::return_status end,approved_by=auth.uid(),decided_at=now(),decision_notes=nullif(trim(p_decision_notes),''),refund_shift_id=v_refund_shift where id=p_return_id;
  return p_return_id;
end $$;

revoke all on function public.open_cash_shift(uuid,numeric) from public;
revoke all on function public.add_cash_movement(uuid,public.cash_movement_type,numeric,text) from public;
revoke all on function public.get_shift_summary(uuid) from public;
revoke all on function public.close_cash_shift(uuid,numeric,text,text) from public;
revoke all on function public.review_cash_shift(uuid,text) from public;
grant execute on function public.open_cash_shift(uuid,numeric) to authenticated;
grant execute on function public.add_cash_movement(uuid,public.cash_movement_type,numeric,text) to authenticated;
grant execute on function public.get_shift_summary(uuid) to authenticated;
grant execute on function public.close_cash_shift(uuid,numeric,text,text) to authenticated;
grant execute on function public.review_cash_shift(uuid,text) to authenticated;
grant select on public.cash_shifts,public.cash_movements to authenticated;

commit;
