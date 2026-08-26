-- Phase 15: Damaged, expired and lost inventory disposal with approval.
-- Run once after 014_branch_expenses.sql.

begin;

create table public.inventory_disposals (
  id uuid primary key default gen_random_uuid(),
  disposal_number bigint generated always as identity unique,
  branch_id uuid not null references public.branches(id),
  reason text not null check(reason in ('expired','damaged','spoiled','missing','recalled','store_use','other')),
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  notes text,
  evidence_reference text,
  submitted_by uuid not null default auth.uid() references auth.users(id),
  submitted_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_notes text
);

create table public.inventory_disposal_items (
  id uuid primary key default gen_random_uuid(),
  disposal_id uuid not null references public.inventory_disposals(id) on delete cascade,
  product_id uuid not null references public.products(id),
  inventory_lot_id uuid references public.inventory_lots(id),
  quantity numeric(12,3) not null check(quantity>0),
  estimated_unit_cost numeric(12,2) not null default 0 check(estimated_unit_cost>=0),
  unique(disposal_id,product_id,inventory_lot_id)
);

create index inventory_disposals_branch_date_idx on public.inventory_disposals(branch_id,submitted_at desc);
create index inventory_disposals_pending_idx on public.inventory_disposals(branch_id,status) where status='pending';
create index inventory_disposal_items_header_idx on public.inventory_disposal_items(disposal_id);

alter table public.inventory_disposals enable row level security;
alter table public.inventory_disposal_items enable row level security;

create policy "staff read permitted disposals" on public.inventory_disposals for select to authenticated
  using(public.can_access_branch(branch_id) and (public.is_admin() or submitted_by=auth.uid()));
create policy "staff read permitted disposal items" on public.inventory_disposal_items for select to authenticated
  using(exists(select 1 from inventory_disposals d where d.id=disposal_id and public.can_access_branch(d.branch_id) and (public.is_admin() or d.submitted_by=auth.uid())));

create or replace function public.submit_inventory_disposal(
  p_branch_id uuid,p_product_id uuid,p_inventory_lot_id uuid,p_quantity numeric,p_reason text,
  p_notes text default null,p_evidence_reference text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;v_stock numeric;v_lot inventory_lots%rowtype;v_cost numeric(12,2);v_product text;
begin
  if not public.is_active_staff() or not public.can_access_branch(p_branch_id) then raise exception 'Branch access required'; end if;
  if p_quantity is null or p_quantity<=0 then raise exception 'Disposal quantity must be positive'; end if;
  if p_reason not in ('expired','damaged','spoiled','missing','recalled','store_use','other') then raise exception 'Invalid disposal reason'; end if;
  select bp.quantity_on_hand,p.name,p.cost_price into v_stock,v_product,v_cost
    from branch_products bp join products p on p.id=bp.product_id
    where bp.branch_id=p_branch_id and bp.product_id=p_product_id and bp.active;
  if v_product is null then raise exception 'Product is not active at this branch'; end if;
  if v_stock<p_quantity then raise exception 'Disposal quantity exceeds current branch stock'; end if;
  if p_inventory_lot_id is not null then
    select * into v_lot from inventory_lots where id=p_inventory_lot_id and branch_id=p_branch_id and product_id=p_product_id;
    if v_lot.id is null then raise exception 'Selected inventory lot does not belong to this product and branch'; end if;
    if v_lot.quantity_remaining<p_quantity then raise exception 'Disposal quantity exceeds the selected lot balance'; end if;
    v_cost:=v_lot.unit_cost;
  end if;
  insert into inventory_disposals(branch_id,reason,notes,evidence_reference)
    values(p_branch_id,p_reason,nullif(trim(p_notes),''),nullif(trim(p_evidence_reference),'')) returning id into v_id;
  insert into inventory_disposal_items(disposal_id,product_id,inventory_lot_id,quantity,estimated_unit_cost)
    values(v_id,p_product_id,p_inventory_lot_id,p_quantity,coalesce(v_cost,0));
  return v_id;
end $$;

create or replace function public.review_inventory_disposal(p_disposal_id uuid,p_approve boolean,p_review_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_disposal inventory_disposals%rowtype;v_item inventory_disposal_items%rowtype;v_lot inventory_lots%rowtype;v_left numeric;v_take numeric;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select * into v_disposal from inventory_disposals where id=p_disposal_id for update;
  if v_disposal.id is null or v_disposal.status<>'pending' or not public.can_access_branch(v_disposal.branch_id) then
    raise exception 'Pending disposal not found or branch access denied';
  end if;
  if p_approve then
    for v_item in select * from inventory_disposal_items where disposal_id=p_disposal_id loop
      update branch_products set quantity_on_hand=quantity_on_hand-v_item.quantity,updated_at=now()
        where branch_id=v_disposal.branch_id and product_id=v_item.product_id and active and quantity_on_hand>=v_item.quantity;
      if not found then raise exception 'Available branch stock is no longer sufficient for this disposal'; end if;
      v_left:=v_item.quantity;
      if v_item.inventory_lot_id is not null then
        update inventory_lots set quantity_remaining=quantity_remaining-v_item.quantity
          where id=v_item.inventory_lot_id and branch_id=v_disposal.branch_id and product_id=v_item.product_id and quantity_remaining>=v_item.quantity;
        if not found then raise exception 'Selected lot stock is no longer sufficient for this disposal'; end if;
        v_left:=0;
      else
        for v_lot in select * from inventory_lots where branch_id=v_disposal.branch_id and product_id=v_item.product_id and quantity_remaining>0
          order by expiry_date asc nulls last,received_at asc for update loop
          v_take:=least(v_left,v_lot.quantity_remaining);
          update inventory_lots set quantity_remaining=quantity_remaining-v_take where id=v_lot.id;
          v_left:=v_left-v_take;exit when v_left<=0;
        end loop;
      end if;
      insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id,notes)
        values(v_disposal.branch_id,v_item.product_id,'disposal',-v_item.quantity,p_disposal_id,
          concat(initcap(replace(v_disposal.reason,'_',' ')),' write-off',case when v_disposal.notes is null then '' else ' · '||v_disposal.notes end));
    end loop;
  end if;
  update inventory_disposals set status=case when p_approve then 'approved' else 'rejected' end,
    reviewed_by=auth.uid(),reviewed_at=now(),review_notes=nullif(trim(p_review_notes),'') where id=p_disposal_id;
  return p_disposal_id;
end $$;

create or replace function public.get_inventory_disposal_summary(p_branch_id uuid,p_from date,p_to date)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_admin boolean:=public.is_admin();v_approved numeric;v_pending bigint;v_units numeric;v_reasons jsonb;
begin
  if not public.is_active_staff() or not public.can_access_branch(p_branch_id) then raise exception 'Branch access required'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'Invalid date range'; end if;
  select coalesce(sum(i.quantity*i.estimated_unit_cost) filter(where d.status='approved'),0),
         count(distinct d.id) filter(where d.status='pending'),coalesce(sum(i.quantity) filter(where d.status='approved'),0)
    into v_approved,v_pending,v_units from inventory_disposals d join inventory_disposal_items i on i.disposal_id=d.id
    where d.branch_id=p_branch_id and d.submitted_at::date between p_from and p_to and (v_admin or d.submitted_by=auth.uid());
  select coalesce(jsonb_agg(to_jsonb(x) order by x.loss desc),'[]'::jsonb) into v_reasons from (
    select d.reason,sum(i.quantity) units,sum(i.quantity*i.estimated_unit_cost) loss,count(distinct d.id) entries
    from inventory_disposals d join inventory_disposal_items i on i.disposal_id=d.id
    where d.branch_id=p_branch_id and d.status='approved' and d.submitted_at::date between p_from and p_to and (v_admin or d.submitted_by=auth.uid()) group by d.reason) x;
  return jsonb_build_object('approved_loss',v_approved,'pending_count',v_pending,'disposed_units',v_units,'by_reason',v_reasons);
end $$;

revoke all on function public.submit_inventory_disposal(uuid,uuid,uuid,numeric,text,text,text) from public;
revoke all on function public.review_inventory_disposal(uuid,boolean,text) from public;
revoke all on function public.get_inventory_disposal_summary(uuid,date,date) from public;
grant execute on function public.submit_inventory_disposal(uuid,uuid,uuid,numeric,text,text,text) to authenticated;
grant execute on function public.review_inventory_disposal(uuid,boolean,text) to authenticated;
grant execute on function public.get_inventory_disposal_summary(uuid,date,date) to authenticated;
grant select on public.inventory_disposals,public.inventory_disposal_items to authenticated;

commit;
