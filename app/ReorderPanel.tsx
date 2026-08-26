"use client";

import { useEffect, useMemo, useState } from "react";
import { supabase } from "../lib/supabase";

type Branch = { id: string; name: string; code: string };
type Supplier = { id: string; name: string };
type Suggestion = {
  product_id: string; name: string; sku: string; barcode: string | null;
  quantity_on_hand: number; reorder_level: number; avg_daily_sales: number;
  on_order: number; incoming_transfer: number; expiring_soon: number;
  target_stock: number; suggested_quantity: number; critical: boolean;
  supplier_id: string | null; supplier_name: string | null; unit_cost: number; lead_time_days: number;
};

export default function ReorderPanel({ branch, onDraftsCreated }: { branch: Branch; onDraftsCreated: () => void }) {
  const [suggestions, setSuggestions] = useState<Suggestion[]>([]);
  const [suppliers, setSuppliers] = useState<Supplier[]>([]);
  const [coverageDays, setCoverageDays] = useState(14);
  const [selected, setSelected] = useState<Record<string, boolean>>({});
  const [quantities, setQuantities] = useState<Record<string, string>>({});
  const [supplierIds, setSupplierIds] = useState<Record<string, string>>({});
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);

  async function load(days = coverageDays) {
    setLoading(true); setMessage("");
    const [suggestionResult, supplierResult] = await Promise.all([
      supabase.rpc("get_reorder_suggestions", { p_branch_id: branch.id, p_coverage_days: days }),
      supabase.from("suppliers").select("id,name").eq("active", true).order("name")
    ]);
    if (suggestionResult.error) setMessage(suggestionResult.error.message);
    else {
      const list = (suggestionResult.data ?? []) as Suggestion[];
      setSuggestions(list);
      setSelected(Object.fromEntries(list.map((s) => [s.product_id, s.suggested_quantity > 0])));
      setQuantities(Object.fromEntries(list.map((s) => [s.product_id, String(s.suggested_quantity)])));
      setSupplierIds(Object.fromEntries(list.map((s) => [s.product_id, s.supplier_id ?? ""])));
    }
    if (supplierResult.error) setMessage(supplierResult.error.message); else setSuppliers((supplierResult.data ?? []) as Supplier[]);
    setLoading(false);
  }

  useEffect(() => { load(); }, [branch.id]);

  async function chooseSupplier(item: Suggestion, supplierId: string) {
    setSupplierIds({ ...supplierIds, [item.product_id]: supplierId });
    if (!supplierId) return;
    const { error } = await supabase.rpc("set_preferred_product_supplier", { p_product_id: item.product_id, p_supplier_id: supplierId, p_unit_cost: item.unit_cost, p_lead_time_days: item.lead_time_days });
    if (error) setMessage(error.message); else setMessage(`${item.name}'s preferred supplier was saved.`);
  }

  async function createDrafts() {
    const items = suggestions.filter((s) => selected[s.product_id]).map((s) => ({ product_id: s.product_id, supplier_id: supplierIds[s.product_id], quantity: Number(quantities[s.product_id]), unit_cost: Number(s.unit_cost) }));
    if (!items.length) { setMessage("Select at least one product."); return; }
    if (items.some((i) => !i.supplier_id || !Number.isFinite(i.quantity) || i.quantity <= 0)) { setMessage("Every selected product needs a supplier and positive quantity."); return; }
    setLoading(true); setMessage("");
    const { data, error } = await supabase.rpc("create_reorder_draft_orders", { p_branch_id: branch.id, p_items: items, p_coverage_days: coverageDays });
    if (error) setMessage(error.message); else { setMessage(`${(data as string[]).length} draft purchase order(s) created successfully.`); onDraftsCreated(); await load(); }
    setLoading(false);
  }

  const critical = suggestions.filter((s) => s.critical).length;
  const selectedCount = suggestions.filter((s) => selected[s.product_id]).length;
  const totalUnits = suggestions.filter((s) => selected[s.product_id]).reduce((sum, s) => sum + Number(quantities[s.product_id] || 0), 0);
  const estimatedCost = suggestions.filter((s) => selected[s.product_id]).reduce((sum, s) => sum + Number(quantities[s.product_id] || 0) * Number(s.unit_cost), 0);
  const groups = useMemo(() => new Set(suggestions.filter((s) => selected[s.product_id] && supplierIds[s.product_id]).map((s) => supplierIds[s.product_id])).size, [suggestions, selected, supplierIds]);
  const money = new Intl.NumberFormat("en-PH", { style: "currency", currency: "PHP" });

  return <section className="workspace inventory-workspace reorder-workspace">
    <header><div><p>Sales-velocity planning and supplier-ready replenishment</p><h1>Reorder Suggestions</h1></div><div className="header-actions"><button disabled={loading} onClick={() => load()}>↻ Refresh</button><button disabled={!selectedCount || loading} onClick={createDrafts}>＋ Create draft POs</button></div></header>
    <div className="inventory-body">
      {message && <p className={/successfully|saved/.test(message) ? "notice" : "notice error"}>{message}</p>}
      <section className="reorder-controls"><div><h2>{branch.code} · {branch.name}</h2><p>Recommendations use the last 30 days of sales, stock on hand, expiring stock, open orders and incoming transfers.</p></div><label>Days of stock<select value={coverageDays} onChange={(e) => { const days = Number(e.target.value); setCoverageDays(days); load(days); }}><option value={7}>7 days</option><option value={14}>14 days</option><option value={21}>21 days</option><option value={30}>30 days</option></select></label></section>
      <div className="inventory-stats reorder-stats"><article><span>Suggested products</span><strong>{suggestions.length}</strong><small>Need replenishment</small></article><article className={critical ? "critical-stat" : ""}><span>Critically low</span><strong>{critical}</strong><small>Immediate attention</small></article><article><span>Selected units</span><strong>{totalUnits}</strong><small>Across {groups} supplier(s)</small></article><article><span>Estimated cost</span><strong>{money.format(estimatedCost)}</strong><small>Using current supplier/product cost</small></article></div>
      <section className="inventory-card"><div className="inventory-card-title"><div><h2>Replenishment plan</h2><p>Review quantities and assign a preferred supplier before generating drafts.</p></div><span className="history-count">{selectedCount} selected</span></div><div className="table-wrap"><table><thead><tr><th>Select</th><th>Product</th><th>Available</th><th>Demand / Target</th><th>Already incoming</th><th>Suggested</th><th>Supplier</th><th>Est. cost</th></tr></thead><tbody>{!suggestions.length && <tr><td colSpan={8}>{loading ? "Calculating suggestions…" : "All products are sufficiently stocked."}</td></tr>}{suggestions.map((s) => <tr key={s.product_id} className={s.critical ? "critical-row" : ""}><td><input type="checkbox" checked={!!selected[s.product_id]} onChange={(e) => setSelected({ ...selected, [s.product_id]: e.target.checked })} /></td><td><strong>{s.name}</strong>{s.critical && <span className="critical-badge">Critical</span>}<small className="cell-sub">{s.sku}{s.expiring_soon > 0 ? ` · ${s.expiring_soon} expiring` : ""}</small></td><td><strong>{s.quantity_on_hand}</strong><small className="cell-sub">Reorder at {s.reorder_level}</small></td><td>{Number(s.avg_daily_sales).toFixed(2)}/day<small className="cell-sub">Target {s.target_stock}</small></td><td>{Number(s.on_order) + Number(s.incoming_transfer)}<small className="cell-sub">PO {s.on_order} · Transfer {s.incoming_transfer}</small></td><td><input className="reorder-qty" min="0" step="1" type="number" value={quantities[s.product_id] ?? ""} onChange={(e) => setQuantities({ ...quantities, [s.product_id]: e.target.value })} /></td><td><select value={supplierIds[s.product_id] ?? ""} onChange={(e) => chooseSupplier(s, e.target.value)}><option value="">Choose supplier…</option>{suppliers.map((supplier) => <option key={supplier.id} value={supplier.id}>{supplier.name}</option>)}</select></td><td><strong>{money.format(Number(quantities[s.product_id] || 0) * Number(s.unit_cost))}</strong><small className="cell-sub">{money.format(Number(s.unit_cost))}/unit</small></td></tr>)}</tbody></table></div></section>
    </div>
  </section>;
}
