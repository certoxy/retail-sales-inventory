-- Phase 4: Duplicate-safe internal barcode generation.
-- Run once after 003_staff_roles.sql.

create sequence if not exists public.internal_barcode_sequence start with 1;

create or replace function public.generate_internal_barcode()
returns text
language plpgsql
security definer
set search_path=public
as $$
declare
  v_barcode text;
begin
  if not public.is_admin() then
    raise exception 'Administrator access required';
  end if;

  loop
    v_barcode := 'RF-' || lpad(nextval('internal_barcode_sequence')::text, 8, '0');
    exit when not exists(select 1 from products where barcode=v_barcode);
  end loop;

  return v_barcode;
end $$;

revoke all on function public.generate_internal_barcode() from public;
grant execute on function public.generate_internal_barcode() to authenticated;
