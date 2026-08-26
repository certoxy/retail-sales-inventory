import test from "node:test";
import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
const migration=async name=>readFile(new URL(`../supabase/migrations/${name}`,import.meta.url),"utf8");

test("checkout and offline sync protect inventory",async()=>{const sql=await migration("016_offline_sales.sql");assert.match(sql,/quantity_on_hand<v_qty/);assert.match(sql,/sales_offline_transaction_uidx/);assert.match(sql,/pg_advisory_xact_lock/)});
test("stock transfers require destination receipt",async()=>{const sql=await migration("006_stock_transfers.sql");assert.match(sql,/receive_stock_transfer/);assert.match(sql,/status='received'/)});
test("stocktakes post through a controlled function",async()=>{const sql=await migration("012_stocktake_physical_count.sql");assert.match(sql,/post_stocktake/);assert.match(sql,/quantity_on_hand=v_item.counted_quantity/)});
test("expenses and disposals require review paths",async()=>{const expense=await migration("014_branch_expenses.sql"),disposal=await migration("015_inventory_disposals.sql");assert.match(expense,/review_branch_expense/);assert.match(disposal,/review_inventory_disposal/);assert.match(disposal,/quantity_on_hand=quantity_on_hand-v_item.quantity/)});
test("system health is administrator-only",async()=>{const sql=await migration("017_system_health.sql");assert.match(sql,/if not public.is_admin\(\)/);assert.match(sql,/Negative inventory/)});
test("audit and recovery controls require administrator evidence",async()=>{const sql=await migration("018_audit_backup_recovery.sql");assert.match(sql,/capture_audit_event/);assert.match(sql,/Administrator access required/);assert.match(sql,/last_verified_at/);assert.match(sql,/Recovery drill passed within 90 days/);assert.match(sql,/This operational snapshot|recent_stock_movements/)});
