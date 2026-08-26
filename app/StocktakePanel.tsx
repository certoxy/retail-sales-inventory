"use client";

import { FormEvent, useEffect, useMemo, useState } from "react";
import { supabase } from "../lib/supabase";

type Branch = { id: string; name: string };
type Item = {
  id: string;
  product_id: string;
  expected_quantity: number;
  counted_quantity: number | null;
  variance: number | null;
  count_notes: string | null;
  products: { name: string; sku: string; barcode: string | null } | null;
};
type Stocktake = {
  id: string;
  stocktake_number: number;
  status: "counting" | "submitted" | "posted" | "cancelled";
  notes: string | null;
  created_at: string;
  stocktake_items: Item[];
};

export default function StocktakePanel({ branch, isAdmin, onInventoryChanged }: { branch: Branch; isAdmin: boolean; onInventoryChanged: () => void }) {
  const [stocktakes, setStocktakes] = useState<Stocktake[]>([]);
  const [active, setActive] = useState<Stocktake | null>(null);
  const [counts, setCounts] = useState<Record<string, string>>({});
  const [itemNotes, setItemNotes] = useState<Record<string, string>>({});
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(false);
  const [search, setSearch] = useState("");
  const [showStart, setShowStart] = useState(false);
  const [sessionNotes, setSessionNotes] = useState("");

  async function load() {
    setLoading(true);
    const { data, error } = await supabase
      .from("stocktakes")
      .select("id,stocktake_number,status,notes,created_at,stocktake_items(id,product_id,expected_quantity,counted_quantity,variance,count_notes,products(name,sku,barcode))")
      .eq("branch_id", branch.id)
      .order("created_at", { ascending: false })
      .limit(30);
    if (error) setMessage(error.message);
    else {
      const list = (data ?? []) as unknown as Stocktake[];
      const current = list.find((s) => s.status === "counting" || s.status === "submitted") ?? null;
      setStocktakes(list);
      setActive(current);
      setCounts(current ? Object.fromEntries(current.stocktake_items.filter((i) => i.counted_quantity !== null).map((i) => [i.product_id, String(i.counted_quantity)])) : {});
      setItemNotes(current ? Object.fromEntries(current.stocktake_items.filter((i) => i.count_notes).map((i) => [i.product_id, i.count_notes!])) : {});
    }
    setLoading(false);
  }

  useEffect(() => { load(); }, [branch.id]);

  async function start(e: FormEvent) {
    e.preventDefault(); setLoading(true); setMessage("");
    const { error } = await supabase.rpc("start_stocktake", { p_branch_id: branch.id, p_notes: sessionNotes.trim() || null });
    if (error) setMessage(error.message);
    else { setMessage("Stocktake started successfully."); setShowStart(false); setSessionNotes(""); await load(); }
    setLoading(false);
  }

  async function save(item: Item) {
    if (!active) return;
    const value = Number(counts[item.product_id]);
    if (!Number.isFinite(value) || value < 0) { setMessage(`Enter a valid count for ${item.products?.name ?? "the product"}.`); return; }
    setLoading(true); setMessage("");
    const { error } = await supabase.rpc("record_stocktake_count", { p_stocktake_id: active.id, p_product_id: item.product_id, p_counted_quantity: value, p_notes: itemNotes[item.product_id]?.trim() || null });
    if (error) setMessage(error.message); else { setMessage(`${item.products?.name ?? "Product"} count saved.`); await load(); }
    setLoading(false);
  }

  async function action(name: "submit_stocktake" | "post_stocktake" | "cancel_stocktake", prompt: string, success: string) {
    if (!active || !window.confirm(prompt)) return;
    setLoading(true); setMessage("");
    const { error } = await supabase.rpc(name, { p_stocktake_id: active.id });
    if (error) setMessage(error.message); else { setMessage(success); await load(); if (name === "post_stocktake") onInventoryChanged(); }
    setLoading(false);
  }

  const visible = useMemo(() => active?.stocktake_items.filter((i) => `${i.products?.name ?? ""} ${i.products?.sku ?? ""} ${i.products?.barcode ?? ""}`.toLowerCase().includes(search.toLowerCase())) ?? [], [active, search]);
  const counted = active?.stocktake_items.filter((i) => i.counted_quantity !== null).length ?? 0;
  const totalVariance = active?.stocktake_items.reduce((sum, i) => sum + Math.abs(Number(i.variance ?? 0)), 0) ?? 0;

  return <section className="workspace inventory-workspace stocktake-workspace">
    <header><div><p>Branch physical count and variance reconciliation</p><h1>Stocktake</h1></div><div className="header-actions"><button onClick={load}>↻ Refresh</button>{isAdmin && !active && <button onClick={() => setShowStart(true)}>＋ Start stocktake</button>}</div></header>
    <div className="inventory-body">
      {message && <p className={/successfully|saved|submitted|cancelled|updated/.test(message) ? "notice" : "notice error"}>{message}</p>}
      {active ? <>
        <section className="stocktake-banner"><div><span className={`stocktake-status ${active.status}`}>{active.status}</span><h2>ST-{String(active.stocktake_number).padStart(5, "0")}</h2><p>{branch.name} · Started {new Date(active.created_at).toLocaleString("en-PH", { dateStyle: "medium", timeStyle: "short" })}</p></div><div className="stocktake-progress"><strong>{counted}/{active.stocktake_items.length}</strong><span>products counted</span><i><b style={{ width: `${active.stocktake_items.length ? counted / active.stocktake_items.length * 100 : 0}%` }} /></i></div><div className="active-shift-actions">{active.status === "counting" && <button disabled={counted !== active.stocktake_items.length || loading} onClick={() => action("submit_stocktake", "Submit this completed count for administrator review?", "Stocktake submitted for posting.")}>Submit count</button>}{isAdmin && active.status === "submitted" && <button className="close-shift" disabled={loading} onClick={() => action("post_stocktake", "Post all variances and replace system quantities with the physical counts?", "Inventory updated successfully.")}>Post variances</button>}{isAdmin && <button disabled={loading} onClick={() => action("cancel_stocktake", "Cancel this stocktake? Saved counts remain in history.", "Stocktake cancelled.")}>Cancel</button>}</div></section>
        <div className="inventory-stats stocktake-stats"><article><span>Products</span><strong>{active.stocktake_items.length}</strong><small>Snapshot at start</small></article><article><span>Counted</span><strong>{counted}</strong><small>{active.stocktake_items.length - counted} remaining</small></article><article><span>Variance units</span><strong>{totalVariance}</strong><small>Absolute difference</small></article><article><span>Status</span><strong>{active.status}</strong><small>{active.status === "counting" ? "Count is editable" : "Awaiting administrator posting"}</small></article></div>
        <section className="inventory-card"><div className="inventory-card-title"><div><h2>Physical count sheet</h2><p>Scan or search each item, enter the physical quantity, then save.</p></div><label className="table-search">⌕ <input value={search} onChange={(e) => setSearch(e.target.value)} placeholder="Product, SKU or barcode…" /></label></div><div className="table-wrap"><table><thead><tr><th>Product</th><th>System qty</th><th>Physical count</th><th>Variance</th><th>Count notes</th><th>Action</th></tr></thead><tbody>{visible.map((item) => { const draft = counts[item.product_id], variance = draft === "" || draft === undefined ? item.variance : Number(draft) - Number(item.expected_quantity); return <tr key={item.id}><td><strong>{item.products?.name ?? "Product"}</strong><small className="cell-sub">{item.products?.sku}{item.products?.barcode ? ` · ${item.products.barcode}` : ""}</small></td><td><strong>{item.expected_quantity}</strong></td><td><input className="count-input" disabled={active.status !== "counting"} min="0" step=".001" type="number" value={draft ?? ""} onChange={(e) => setCounts({ ...counts, [item.product_id]: e.target.value })} placeholder="Count" /></td><td><strong className={Number(variance ?? 0) > 0 ? "positive" : Number(variance ?? 0) < 0 ? "negative" : ""}>{variance === null ? "—" : Number(variance) > 0 ? `+${variance}` : variance}</strong></td><td><input disabled={active.status !== "counting"} value={itemNotes[item.product_id] ?? ""} onChange={(e) => setItemNotes({ ...itemNotes, [item.product_id]: e.target.value })} placeholder="Damage, missing, recount…" /></td><td>{active.status === "counting" ? <button className="stock-action receive-action" disabled={loading || draft === undefined || draft === ""} onClick={() => save(item)}>Save count</button> : <span className="cell-sub">Locked</span>}</td></tr>; })}</tbody></table></div></section>
      </> : <section className="no-active-shift"><span>≋</span><div><h2>No active stocktake</h2><p>Start a physical count for {branch.name}. System quantities are captured when the session begins.</p></div>{isAdmin && <button onClick={() => setShowStart(true)}>Start stocktake</button>}</section>}
      <section className="inventory-card"><div className="inventory-card-title"><div><h2>Stocktake history</h2><p>Posted and cancelled sessions remain available as an audit trail.</p></div></div><div className="table-wrap"><table><thead><tr><th>Stocktake</th><th>Date</th><th>Products</th><th>Counted</th><th>Variance units</th><th>Status</th></tr></thead><tbody>{!stocktakes.length && <tr><td colSpan={6}>{loading ? "Loading…" : "No stocktakes at this branch."}</td></tr>}{stocktakes.map((s) => <tr key={s.id}><td><strong>ST-{String(s.stocktake_number).padStart(5, "0")}</strong>{s.notes && <small className="cell-sub">{s.notes}</small>}</td><td>{new Date(s.created_at).toLocaleString("en-PH", { dateStyle: "medium", timeStyle: "short" })}</td><td>{s.stocktake_items.length}</td><td>{s.stocktake_items.filter((i) => i.counted_quantity !== null).length}</td><td><strong>{s.stocktake_items.reduce((sum, i) => sum + Math.abs(Number(i.variance ?? 0)), 0)}</strong></td><td><span className={`stocktake-status ${s.status}`}>{s.status}</span></td></tr>)}</tbody></table></div></section>
    </div>
    {showStart && <div className="modal-backdrop"><form className="modal compact" onSubmit={start}><div className="modal-title"><div><h2>Start physical stocktake</h2><p>{branch.name} · Active products and current quantities will be captured.</p></div><button type="button" onClick={() => setShowStart(false)}>×</button></div><label>Count notes<textarea value={sessionNotes} onChange={(e) => setSessionNotes(e.target.value)} placeholder="Full store count, aisle or schedule details…" /></label><div className="stocktake-warning"><strong>Recommended: count while the branch is closed</strong><span>Sales, deliveries and transfers during counting can create misleading variances.</span></div><div className="modal-actions"><button type="button" onClick={() => setShowStart(false)}>Cancel</button><button disabled={loading} type="submit">Start count</button></div></form></div>}
  </section>;
}
