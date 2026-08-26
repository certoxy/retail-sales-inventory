-- Phase 10: Partial returns, approval, refunds/exchanges and audit receipts.
-- Run once after 009_receipt_printing.sql.

begin;

create type public.return_status as enum ('pending','approved','rejected');
create type public.return_outcome as enum ('refund','exchange');
create type public.return_disposition as enum ('restock','damaged','expired');

create table public.returns (
  id uuid primary key default gen_random_uuid(),
  return_number bigint generated always as identity unique,
  sale_id uuid not null references public.sales(id),
  branch_id uuid not null references public.branches(id),
  status public.return_status not null default 'pending',
  outcome public.return_outcome not null,
  refund_method text check(refund_method in ('cash','card','gcash','original')),
  reason text not null check(reason in ('defective','expired','incorrect_item','changed_mind','other')),
  notes text,
  decision_notes text,
  total_amount numeric(12,2) not null default 0 check(total_amount>=0),
  requested_by uuid not null default auth.uid() references auth.users(id),
  approved_by uuid references auth.users(id),
  requested_at timestamptz not null default now(),
  decided_at timestamptz
);

create table public.return_items (
  id uuid primary key default gen_random_uuid(),
  return_id uuid not null references public.returns(id) on delete cascade,
  sale_item_id uuid not null references public.sale_items(id),
  product_id uuid not null references public.products(id),
  quantity numeric(12,3) not null check(quantity>0),
  unit_price numeric(12,2) not null check(unit_price>=0),
  disposition public.return_disposition not null,
  line_total numeric(12,2) generated always as (round(quantity*unit_price,2)) stored,
  unique(return_id,sale_item_id)
);

create index returns_branch_status_idx on public.returns(branch_id,status,requested_at desc);
create index return_items_return_idx on public.return_items(return_id);

alter table public.returns enable row level security;
alter table public.return_items enable row level security;

create policy "staff read permitted returns" on public.returns for select to authenticated
  using(public.can_access_branch(branch_id) and (requested_by=auth.uid() or public.is_admin()));
create policy "staff read permitted return items" on public.return_items for select to authenticated
  using(exists(select 1 from returns r where r.id=return_id and public.can_access_branch(r.branch_id) and (r.requested_by=auth.uid() or public.is_admin())));

-- Extend receipt items with their sale-item IDs so eligible quantities can be returned.
create or replace function public.get_sale_receipt(p_sale_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_sale sales%rowtype;v_branch branches%rowtype;v_cashier text;v_items jsonb;
begin
  if not public.is_active_staff() then raise exception 'Active staff access required'; end if;
  select * into v_sale from sales where id=p_sale_id;
  if v_sale.id is null then raise exception 'Sale not found'; end if;
  if not public.can_access_branch(v_sale.branch_id) or (not public.is_admin() and v_sale.cashier_id<>auth.uid()) then raise exception 'Receipt access denied'; end if;
  select * into v_branch from branches where id=v_sale.branch_id;
  select coalesce(nullif(full_name,''),email) into v_cashier from profiles where id=v_sale.cashier_id;
  select coalesce(jsonb_agg(jsonb_build_object('sale_item_id',si.id,'name',p.name,'sku',p.sku,'quantity',si.quantity,'unit_price',si.unit_price,'line_total',si.line_total) order by si.id),'[]'::jsonb)
    into v_items from sale_items si join products p on p.id=si.product_id where si.sale_id=p_sale_id;
  return jsonb_build_object('id',v_sale.id,'receipt_number',v_sale.receipt_number,'created_at',v_sale.created_at,'branch_name',v_branch.name,'branch_code',v_branch.code,'branch_address',v_branch.address,
    'cashier',coalesce(v_cashier,'Staff'),'payment_method',v_sale.payment_method,'subtotal',v_sale.subtotal,'vat_amount',v_sale.vat_amount,'total',v_sale.total,'items',v_items);
end $$;

create or replace function public.create_return_request(
  p_sale_id uuid,p_items jsonb,p_outcome public.return_outcome,p_refund_method text,p_reason text,p_notes text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_sale sales%rowtype;v_return_id uuid;v_item jsonb;v_sale_item sale_items%rowtype;v_qty numeric(12,3);v_prior numeric(12,3);v_disposition public.return_disposition;v_total numeric(12,2):=0;
begin
  if not public.is_active_staff() then raise exception 'Active staff access required'; end if;
  select * into v_sale from sales where id=p_sale_id;
  if v_sale.id is null or not public.can_access_branch(v_sale.branch_id) then raise exception 'Sale not found or branch access denied'; end if;
  if p_items is null or jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Select at least one item to return'; end if;
  if p_reason not in ('defective','expired','incorrect_item','changed_mind','other') then raise exception 'Invalid return reason'; end if;
  if p_outcome='refund' and p_refund_method not in ('cash','card','gcash','original') then raise exception 'Refund method required'; end if;
  insert into returns(sale_id,branch_id,outcome,refund_method,reason,notes)
  values(p_sale_id,v_sale.branch_id,p_outcome,case when p_outcome='refund' then p_refund_method else null end,p_reason,nullif(trim(p_notes),'')) returning id into v_return_id;
  for v_item in select * from jsonb_array_elements(p_items) loop
    select * into v_sale_item from sale_items where id=(v_item->>'sale_item_id')::uuid and sale_id=p_sale_id;
    v_qty:=(v_item->>'quantity')::numeric;v_disposition:=(v_item->>'disposition')::public.return_disposition;
    select coalesce(sum(ri.quantity),0) into v_prior from return_items ri join returns r on r.id=ri.return_id where ri.sale_item_id=v_sale_item.id and r.status in ('pending','approved');
    if v_sale_item.id is null or v_qty<=0 or v_prior+v_qty>v_sale_item.quantity then raise exception 'Return quantity exceeds the remaining sold quantity'; end if;
    insert into return_items(return_id,sale_item_id,product_id,quantity,unit_price,disposition)
    values(v_return_id,v_sale_item.id,v_sale_item.product_id,v_qty,v_sale_item.unit_price,v_disposition);
    v_total:=v_total+round(v_qty*v_sale_item.unit_price,2);
  end loop;
  update returns set total_amount=v_total where id=v_return_id;
  return v_return_id;
end $$;

create or replace function public.decide_return(p_return_id uuid,p_approve boolean,p_decision_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_return returns%rowtype;v_item return_items%rowtype;
begin
  if not public.is_admin() then raise exception 'Administrator approval required'; end if;
  select * into v_return from returns where id=p_return_id for update;
  if v_return.id is null or not public.can_access_branch(v_return.branch_id) then raise exception 'Return not found or branch access denied'; end if;
  if v_return.status<>'pending' then raise exception 'Return has already been decided'; end if;
  if p_approve then
    for v_item in select * from return_items where return_id=p_return_id loop
      if v_item.disposition='restock' then
        update branch_products set quantity_on_hand=quantity_on_hand+v_item.quantity,updated_at=now() where branch_id=v_return.branch_id and product_id=v_item.product_id;
        if not found then raise exception 'Branch product setup is missing'; end if;
        insert into inventory_lots(branch_id,product_id,quantity_received,quantity_remaining,unit_cost)
        select v_return.branch_id,v_item.product_id,v_item.quantity,v_item.quantity,p.cost_price from products p where p.id=v_item.product_id;
        insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id,notes)
        values(v_return.branch_id,v_item.product_id,'return',v_item.quantity,p_return_id,'Approved customer return');
      end if;
    end loop;
  end if;
  update returns set status=case when p_approve then 'approved'::return_status else 'rejected'::return_status end,
    approved_by=auth.uid(),decided_at=now(),decision_notes=nullif(trim(p_decision_notes),'') where id=p_return_id;
  return p_return_id;
end $$;

create or replace function public.get_return_receipt(p_return_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_return returns%rowtype;v_sale sales%rowtype;v_branch branches%rowtype;v_staff text;v_items jsonb;
begin
  if not public.is_active_staff() then raise exception 'Active staff access required'; end if;
  select * into v_return from returns where id=p_return_id;
  if v_return.id is null or not public.can_access_branch(v_return.branch_id) or (not public.is_admin() and v_return.requested_by<>auth.uid()) then raise exception 'Return receipt access denied'; end if;
  select * into v_sale from sales where id=v_return.sale_id;select * into v_branch from branches where id=v_return.branch_id;
  select coalesce(nullif(full_name,''),email) into v_staff from profiles where id=v_return.requested_by;
  select coalesce(jsonb_agg(jsonb_build_object('name',p.name,'sku',p.sku,'quantity',ri.quantity,'unit_price',ri.unit_price,'line_total',ri.line_total,'disposition',ri.disposition) order by ri.id),'[]'::jsonb)
    into v_items from return_items ri join products p on p.id=ri.product_id where ri.return_id=p_return_id;
  return jsonb_build_object('id',v_return.id,'return_number',v_return.return_number,'original_receipt_number',v_sale.receipt_number,'requested_at',v_return.requested_at,'decided_at',v_return.decided_at,
    'branch_name',v_branch.name,'branch_code',v_branch.code,'branch_address',v_branch.address,'staff',coalesce(v_staff,'Staff'),'status',v_return.status,'outcome',v_return.outcome,
    'refund_method',v_return.refund_method,'reason',v_return.reason,'notes',v_return.notes,'decision_notes',v_return.decision_notes,'total_amount',v_return.total_amount,'items',v_items);
end $$;

revoke all on function public.create_return_request(uuid,jsonb,public.return_outcome,text,text,text) from public;
revoke all on function public.decide_return(uuid,boolean,text) from public;
revoke all on function public.get_return_receipt(uuid) from public;
grant execute on function public.create_return_request(uuid,jsonb,public.return_outcome,text,text,text) to authenticated;
grant execute on function public.decide_return(uuid,boolean,text) to authenticated;
grant execute on function public.get_return_receipt(uuid) to authenticated;
grant select on public.returns,public.return_items to authenticated;

commit;
