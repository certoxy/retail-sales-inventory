-- Phase 6: Confirmed branch-to-branch stock transfers.
-- Run once after 005_multibranch_foundation.sql.

begin;

alter table public.stock_movements
  drop constraint if exists stock_movements_movement_type_check;
alter table public.stock_movements
  add constraint stock_movements_movement_type_check
  check(movement_type in ('opening','purchase','sale','adjustment','return','transfer_out','transfer_in'));

create type public.transfer_status as enum ('in_transit','received');

create table public.stock_transfers (
  id uuid primary key default gen_random_uuid(),
  transfer_number bigint generated always as identity unique,
  from_branch_id uuid not null references public.branches(id),
  to_branch_id uuid not null references public.branches(id),
  status public.transfer_status not null default 'in_transit',
  notes text,
  sent_by uuid not null default auth.uid() references auth.users(id),
  received_by uuid references auth.users(id),
  sent_at timestamptz not null default now(),
  received_at timestamptz,
  check(from_branch_id<>to_branch_id)
);

create table public.stock_transfer_items (
  id uuid primary key default gen_random_uuid(),
  transfer_id uuid not null references public.stock_transfers(id) on delete cascade,
  product_id uuid not null references public.products(id),
  quantity numeric(12,3) not null check(quantity>0),
  unique(transfer_id,product_id)
);

create index transfers_from_status_idx on public.stock_transfers(from_branch_id,status,sent_at desc);
create index transfers_to_status_idx on public.stock_transfers(to_branch_id,status,sent_at desc);

alter table public.stock_transfers enable row level security;
alter table public.stock_transfer_items enable row level security;

create policy "staff read accessible transfers" on public.stock_transfers for select to authenticated
  using(public.can_access_branch(from_branch_id) or public.can_access_branch(to_branch_id));
create policy "staff read accessible transfer items" on public.stock_transfer_items for select to authenticated
  using(exists(select 1 from stock_transfers t where t.id=transfer_id and
    (public.can_access_branch(t.from_branch_id) or public.can_access_branch(t.to_branch_id))));

create or replace function public.send_stock_transfer(
  p_from_branch_id uuid,p_to_branch_id uuid,p_items jsonb,p_notes text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_transfer_id uuid;v_item jsonb;v_product_id uuid;v_qty numeric(12,3);v_name text;
begin
  if not public.is_admin() or not public.can_access_branch(p_from_branch_id) or not public.can_access_branch(p_to_branch_id) then
    raise exception 'Administrator branch access required';
  end if;
  if p_from_branch_id=p_to_branch_id then raise exception 'Source and destination branches must differ'; end if;
  if jsonb_array_length(p_items)=0 then raise exception 'Transfer must contain at least one item'; end if;

  insert into stock_transfers(from_branch_id,to_branch_id,notes)
  values(p_from_branch_id,p_to_branch_id,nullif(trim(p_notes),''))
  returning id into v_transfer_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_product_id:=(v_item->>'product_id')::uuid;
    v_qty:=(v_item->>'quantity')::numeric;
    if v_qty<=0 then raise exception 'Transfer quantities must be positive'; end if;
    select p.name into v_name from products p where p.id=v_product_id;
    update branch_products set quantity_on_hand=quantity_on_hand-v_qty,updated_at=now()
      where branch_id=p_from_branch_id and product_id=v_product_id and active
        and quantity_on_hand>=v_qty;
    if not found then raise exception 'Insufficient source stock for %',coalesce(v_name,'product'); end if;
    insert into stock_transfer_items(transfer_id,product_id,quantity)
    values(v_transfer_id,v_product_id,v_qty);
    insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id,notes)
    values(p_from_branch_id,v_product_id,'transfer_out',-v_qty,v_transfer_id,'Transfer sent');
  end loop;
  return v_transfer_id;
end $$;

create or replace function public.receive_stock_transfer(p_transfer_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_transfer stock_transfers%rowtype;v_item stock_transfer_items%rowtype;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select * into v_transfer from stock_transfers where id=p_transfer_id for update;
  if v_transfer.id is null then raise exception 'Transfer not found'; end if;
  if not public.can_access_branch(v_transfer.to_branch_id) then raise exception 'Destination branch access required'; end if;
  if v_transfer.status<>'in_transit' then raise exception 'Transfer has already been received'; end if;
  for v_item in select * from stock_transfer_items where transfer_id=p_transfer_id loop
    update branch_products set quantity_on_hand=quantity_on_hand+v_item.quantity,updated_at=now()
      where branch_id=v_transfer.to_branch_id and product_id=v_item.product_id;
    if not found then raise exception 'Destination product setup is missing'; end if;
    insert into stock_movements(branch_id,product_id,movement_type,quantity_change,reference_id,notes)
    values(v_transfer.to_branch_id,v_item.product_id,'transfer_in',v_item.quantity,p_transfer_id,'Transfer received');
  end loop;
  update stock_transfers set status='received',received_by=auth.uid(),received_at=now()
    where id=p_transfer_id;
  return p_transfer_id;
end $$;

revoke all on function public.send_stock_transfer(uuid,uuid,jsonb,text) from public;
revoke all on function public.receive_stock_transfer(uuid) from public;
grant execute on function public.send_stock_transfer(uuid,uuid,jsonb,text) to authenticated;
grant execute on function public.receive_stock_transfer(uuid) to authenticated;
grant select on public.stock_transfers,public.stock_transfer_items to authenticated;

commit;
