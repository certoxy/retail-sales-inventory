-- Phase 12: Branch stocktake sessions and physical inventory reconciliation.
-- Run once after 011_cashier_shifts.sql.

begin;

create type public.stocktake_status as enum ('counting','submitted','posted','cancelled');

alter table public.stock_movements drop constraint if exists stock_movements_movement_type_check;
alter table public.stock_movements add constraint stock_movements_movement_type_check
  check(movement_type in ('opening','purchase','sale','adjustment','return','transfer_out','transfer_in','stocktake'));

create table public.stocktakes (
  id uuid primary key default gen_random_uuid(),
  stocktake_number bigint generated always as identity unique,
  branch_id uuid not null references public.branches(id),
  status public.stocktake_status not null default 'counting',
  notes text,
  created_by uuid not null default auth.uid() references auth.users(id),
  created_at timestamptz not null default now(),
  submitted_by uuid references auth.users(id),
  submitted_at timestamptz,
  posted_by uuid references auth.users(id),
  posted_at timestamptz,
  cancelled_by uuid references auth.users(id),
  cancelled_at timestamptz
);

create unique index one_active_stocktake_per_branch
  on public.stocktakes(branch_id) where status in ('counting','submitted');
create index stocktakes_branch_date_idx on public.stocktakes(branch_id,created_at desc);

create table public.stocktake_items (
  id uuid primary key default gen_random_uuid(),
  stocktake_id uuid not null references public.stocktakes(id) on delete cascade,
  product_id uuid not null references public.products(id),
  expected_quantity numeric(12,3) not null,
  counted_quantity numeric(12,3) check(counted_quantity>=0),
  variance numeric(12,3) generated always as
    (case when counted_quantity is null then null else counted_quantity-expected_quantity end) stored,
  count_notes text,
  counted_by uuid references auth.users(id),
  counted_at timestamptz,
  unique(stocktake_id,product_id)
);

alter table public.stocktakes enable row level security;
alter table public.stocktake_items enable row level security;

create policy "staff read permitted stocktakes" on public.stocktakes for select to authenticated
  using(public.can_access_branch(branch_id));
create policy "staff read permitted stocktake items" on public.stocktake_items for select to authenticated
  using(exists(select 1 from public.stocktakes s where s.id=stocktake_id and public.can_access_branch(s.branch_id)));

create or replace function public.start_stocktake(p_branch_id uuid,p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if not public.is_admin() or not public.can_access_branch(p_branch_id) then raise exception 'Administrator branch access required'; end if;
  if exists(select 1 from stocktakes where branch_id=p_branch_id and status in ('counting','submitted')) then raise exception 'This branch already has an active stocktake'; end if;
  insert into stocktakes(branch_id,notes) values(p_branch_id,nullif(trim(p_notes),'')) returning id into v_id;
  insert into stocktake_items(stocktake_id,product_id,expected_quantity)
    select v_id,bp.product_id,bp.quantity_on_hand from branch_products bp join products p on p.id=bp.product_id
    where bp.branch_id=p_branch_id and bp.active and p.active order by p.name;
  return v_id;
end $$;

create or replace function public.record_stocktake_count(p_stocktake_id uuid,p_product_id uuid,p_counted_quantity numeric,p_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_branch uuid;v_item uuid;
begin
  select branch_id into v_branch from stocktakes where id=p_stocktake_id and status='counting';
  if v_branch is null or not public.is_active_staff() or not public.can_access_branch(v_branch) then raise exception 'Active stocktake access required'; end if;
  if p_counted_quantity<0 then raise exception 'Counted quantity cannot be negative'; end if;
  update stocktake_items set counted_quantity=p_counted_quantity,count_notes=nullif(trim(p_notes),''),counted_by=auth.uid(),counted_at=now()
    where stocktake_id=p_stocktake_id and product_id=p_product_id returning id into v_item;
  if v_item is null then raise exception 'Product is not part of this stocktake'; end if;
  return v_item;
end $$;

create or replace function public.submit_stocktake(p_stocktake_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_branch uuid;
begin
  select branch_id into v_branch from stocktakes where id=p_stocktake_id and status='counting' for update;
  if v_branch is null or not public.is_active_staff() or not public.can_access_branch(v_branch) then raise exception 'Active stocktake access required'; end if;
  if exists(select 1 from stocktake_items where stocktake_id=p_stocktake_id and counted_quantity is null) then raise exception 'Count every product before submitting'; end if;
  update stocktakes set status='submitted',submitted_by=auth.uid(),submitted_at=now() where id=p_stocktake_id;
  return p_stocktake_id;
end $$;

create or replace function public.post_stocktake(p_stocktake_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_take numeric(12,3);v_left numeric(12,3);v_item stocktake_items%rowtype;v_lot inventory_lots%rowtype;v_branch uuid;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select branch_id into v_branch from stocktakes where id=p_stocktake_id and status='submitted' for update;
  if v_branch is null or not public.can_access_branch(v_branch) then raise exception 'Submitted stocktake not found or branch access denied'; end if;
  for v_item in select * from stocktake_items where stocktake_id=p_stocktake_id for update loop
    update branch_products set quantity_on_hand=v_item.counted_quantity,updated_at=now()
      where branch_id=v_branch and product_id=v_item.product_id;
    if v_item.variance<>0 then
      insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id,notes)
        values(v_branch,v_item.product_id,'stocktake',v_item.variance,p_stocktake_id,
          concat('Physical count: expected ',v_item.expected_quantity,', counted ',v_item.counted_quantity,
            case when v_item.count_notes is null then '' else '. '||v_item.count_notes end));
      if v_item.variance>0 then
        insert into inventory_lots(branch_id,product_id,quantity_received,quantity_remaining,unit_cost)
          select v_branch,v_item.product_id,v_item.variance,v_item.variance,p.cost_price from products p where p.id=v_item.product_id;
      else
        v_left:=-v_item.variance;
        for v_lot in select * from inventory_lots where branch_id=v_branch and product_id=v_item.product_id and quantity_remaining>0
          order by expiry_date asc nulls last,received_at asc for update loop
          v_take:=least(v_left,v_lot.quantity_remaining);
          update inventory_lots set quantity_remaining=quantity_remaining-v_take where id=v_lot.id;
          v_left:=v_left-v_take;exit when v_left<=0;
        end loop;
      end if;
    end if;
  end loop;
  update stocktakes set status='posted',posted_by=auth.uid(),posted_at=now() where id=p_stocktake_id;
  return p_stocktake_id;
end $$;

create or replace function public.cancel_stocktake(p_stocktake_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_branch uuid;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select branch_id into v_branch from stocktakes where id=p_stocktake_id and status in ('counting','submitted') for update;
  if v_branch is null or not public.can_access_branch(v_branch) then raise exception 'Active stocktake not found or branch access denied'; end if;
  update stocktakes set status='cancelled',cancelled_by=auth.uid(),cancelled_at=now() where id=p_stocktake_id;
  return p_stocktake_id;
end $$;

revoke all on function public.start_stocktake(uuid,text) from public;
revoke all on function public.record_stocktake_count(uuid,uuid,numeric,text) from public;
revoke all on function public.submit_stocktake(uuid) from public;
revoke all on function public.post_stocktake(uuid) from public;
revoke all on function public.cancel_stocktake(uuid) from public;
grant execute on function public.start_stocktake(uuid,text) to authenticated;
grant execute on function public.record_stocktake_count(uuid,uuid,numeric,text) to authenticated;
grant execute on function public.submit_stocktake(uuid) to authenticated;
grant execute on function public.post_stocktake(uuid) to authenticated;
grant execute on function public.cancel_stocktake(uuid) to authenticated;
grant select on public.stocktakes,public.stocktake_items to authenticated;

commit;
