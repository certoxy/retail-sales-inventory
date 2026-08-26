-- Phase 14: Branch expense tracking, approvals and cashier-shift cash integration.
-- Run once after 013_reorder_suggestions.sql.

begin;

create table public.expense_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  active boolean not null default true,
  created_at timestamptz not null default now()
);

insert into public.expense_categories(name) values
  ('Utilities'),('Rent'),('Transportation'),('Store Supplies'),('Repairs & Maintenance'),
  ('Petty Cash'),('Government Fees'),('Marketing'),('Meals'),('Other')
on conflict(name) do nothing;

create table public.expenses (
  id uuid primary key default gen_random_uuid(),
  expense_number bigint generated always as identity unique,
  branch_id uuid not null references public.branches(id),
  category_id uuid not null references public.expense_categories(id),
  amount numeric(12,2) not null check(amount>0),
  payment_method text not null check(payment_method in ('cash','card','gcash','bank')),
  expense_date date not null default current_date,
  payee text,
  reference_number text,
  notes text,
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  submitted_by uuid not null default auth.uid() references auth.users(id),
  submitted_at timestamptz not null default now(),
  reviewed_by uuid references auth.users(id),
  reviewed_at timestamptz,
  review_notes text,
  shift_id uuid references public.cash_shifts(id),
  cash_movement_id uuid references public.cash_movements(id),
  reversal_cash_movement_id uuid references public.cash_movements(id)
);

create index expenses_branch_date_idx on public.expenses(branch_id,expense_date desc,submitted_at desc);
create index expenses_status_idx on public.expenses(status) where status='pending';

alter table public.expense_categories enable row level security;
alter table public.expenses enable row level security;
create policy "staff read expense categories" on public.expense_categories for select to authenticated using(active or public.is_admin());
create policy "admins manage expense categories" on public.expense_categories for all to authenticated using(public.is_admin()) with check(public.is_admin());
create policy "staff read permitted expenses" on public.expenses for select to authenticated
  using(public.can_access_branch(branch_id) and (public.is_admin() or submitted_by=auth.uid()));

create or replace function public.record_branch_expense(
  p_branch_id uuid,p_category_id uuid,p_amount numeric,p_payment_method text,p_expense_date date,
  p_payee text default null,p_reference_number text default null,p_notes text default null
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;v_shift uuid;v_movement uuid;v_status text;v_category text;
begin
  if not public.is_active_staff() or not public.can_access_branch(p_branch_id) then raise exception 'Branch access required'; end if;
  if p_amount<=0 or p_expense_date is null then raise exception 'Positive amount and expense date required'; end if;
  if p_payment_method not in ('cash','card','gcash','bank') then raise exception 'Invalid payment method'; end if;
  select name into v_category from expense_categories where id=p_category_id and active;
  if v_category is null then raise exception 'Active expense category required'; end if;
  v_status:=case when public.is_admin() then 'approved' else 'pending' end;
  if p_payment_method='cash' then
    select id into v_shift from cash_shifts where cashier_id=auth.uid() and branch_id=p_branch_id and status='open';
    if v_shift is null then raise exception 'Open a cashier shift before recording a cash expense'; end if;
  end if;
  insert into expenses(branch_id,category_id,amount,payment_method,expense_date,payee,reference_number,notes,status,reviewed_by,reviewed_at,shift_id)
    values(p_branch_id,p_category_id,p_amount,p_payment_method,p_expense_date,nullif(trim(p_payee),''),nullif(trim(p_reference_number),''),nullif(trim(p_notes),''),v_status,
      case when v_status='approved' then auth.uid() end,case when v_status='approved' then now() end,v_shift) returning id into v_id;
  if p_payment_method='cash' then
    insert into cash_movements(shift_id,movement_type,amount,reason)
      values(v_shift,'cash_out',p_amount,concat('Expense · ',v_category,case when nullif(trim(p_payee),'') is null then '' else ' · '||trim(p_payee) end)) returning id into v_movement;
    update expenses set cash_movement_id=v_movement where id=v_id;
  end if;
  return v_id;
end $$;

create or replace function public.review_branch_expense(p_expense_id uuid,p_approve boolean,p_review_notes text default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_expense expenses%rowtype;v_reversal uuid;v_shift_status public.cash_shift_status;
begin
  if not public.is_admin() then raise exception 'Administrator access required'; end if;
  select * into v_expense from expenses where id=p_expense_id for update;
  if v_expense.id is null or not public.can_access_branch(v_expense.branch_id) or v_expense.status<>'pending' then raise exception 'Pending expense not found or branch access denied'; end if;
  if not p_approve and v_expense.payment_method='cash' then
    select status into v_shift_status from cash_shifts where id=v_expense.shift_id;
    if v_shift_status<>'open' then raise exception 'A cash expense cannot be rejected after its cashier shift is closed'; end if;
    insert into cash_movements(shift_id,movement_type,amount,reason)
      values(v_expense.shift_id,'cash_in',v_expense.amount,concat('Rejected expense reversal · EX-',lpad(v_expense.expense_number::text,6,'0'))) returning id into v_reversal;
  end if;
  update expenses set status=case when p_approve then 'approved' else 'rejected' end,reviewed_by=auth.uid(),reviewed_at=now(),
    review_notes=nullif(trim(p_review_notes),''),reversal_cash_movement_id=v_reversal where id=p_expense_id;
  return p_expense_id;
end $$;

create or replace function public.get_expense_summary(p_branch_id uuid,p_from date,p_to date)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_admin boolean:=public.is_admin();v_approved numeric;v_pending numeric;v_count bigint;v_categories jsonb;v_methods jsonb;
begin
  if not public.is_active_staff() then raise exception 'Active staff access required'; end if;
  if p_from is null or p_to is null or p_from>p_to then raise exception 'Invalid date range'; end if;
  if p_branch_id is not null and not public.can_access_branch(p_branch_id) then raise exception 'Branch access required'; end if;
  if not v_admin and p_branch_id is null then raise exception 'Cashiers must select an assigned branch'; end if;
  select coalesce(sum(amount) filter(where status='approved'),0),coalesce(sum(amount) filter(where status='pending'),0),count(*) filter(where status='approved')
    into v_approved,v_pending,v_count from expenses e where expense_date between p_from and p_to and (p_branch_id is null or branch_id=p_branch_id) and (v_admin or submitted_by=auth.uid());
  select coalesce(jsonb_agg(to_jsonb(x) order by x.amount desc),'[]'::jsonb) into v_categories from (
    select ec.name,sum(e.amount) amount,count(*) entries from expenses e join expense_categories ec on ec.id=e.category_id
    where e.status='approved' and e.expense_date between p_from and p_to and (p_branch_id is null or e.branch_id=p_branch_id) and (v_admin or e.submitted_by=auth.uid()) group by ec.name) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.amount desc),'[]'::jsonb) into v_methods from (
    select e.payment_method method,sum(e.amount) amount,count(*) entries from expenses e
    where e.status='approved' and e.expense_date between p_from and p_to and (p_branch_id is null or e.branch_id=p_branch_id) and (v_admin or e.submitted_by=auth.uid()) group by e.payment_method) x;
  return jsonb_build_object('approved_expenses',v_approved,'pending_expenses',v_pending,'approved_count',v_count,'by_category',v_categories,'by_method',v_methods);
end $$;

revoke all on function public.record_branch_expense(uuid,uuid,numeric,text,date,text,text,text) from public;
revoke all on function public.review_branch_expense(uuid,boolean,text) from public;
revoke all on function public.get_expense_summary(uuid,date,date) from public;
grant execute on function public.record_branch_expense(uuid,uuid,numeric,text,date,text,text,text) to authenticated;
grant execute on function public.review_branch_expense(uuid,boolean,text) to authenticated;
grant execute on function public.get_expense_summary(uuid,date,date) to authenticated;
grant select on public.expense_categories,public.expenses to authenticated;

commit;
