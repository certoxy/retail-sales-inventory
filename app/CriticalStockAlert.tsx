"use client";

import { useEffect, useState } from "react";

type Product = { id: string; name: string; sku: string; stock: number; reorder: number };

export default function CriticalStockAlert({ branchId, branchName, products, onReview }: { branchId: string; branchName: string; products: Product[]; onReview: () => void }) {
  const critical = products.filter((p) => p.stock <= Math.max(1, p.reorder * .25));
  const [open, setOpen] = useState(false);
  useEffect(() => {
    if (!critical.length) { setOpen(false); return; }
    const key = `retailflow-critical-alert-${branchId}`;
    if (sessionStorage.getItem(key) !== new Date().toISOString().slice(0, 10)) setOpen(true);
  }, [branchId, critical.length]);
  function dismiss() { sessionStorage.setItem(`retailflow-critical-alert-${branchId}`, new Date().toISOString().slice(0, 10)); setOpen(false); }
  if (!open) return null;
  return <div className="modal-backdrop critical-alert-backdrop"><section className="critical-alert" role="alertdialog" aria-modal="true" aria-labelledby="critical-stock-title"><div className="critical-alert-icon">!</div><div><span className="critical-eyebrow">Inventory alert · {branchName}</span><h2 id="critical-stock-title">{critical.length} product{critical.length === 1 ? " is" : "s are"} critically low</h2><p>These products are at 25% or less of their reorder level and need immediate attention.</p><div className="critical-product-list">{critical.slice(0, 6).map((p) => <article key={p.id}><span><strong>{p.name}</strong><small>{p.sku}</small></span><b className={p.stock <= 0 ? "out" : ""}>{p.stock <= 0 ? "Out of stock" : `${p.stock} left`}</b></article>)}{critical.length > 6 && <small>＋ {critical.length - 6} more critically low products</small>}</div><div className="critical-alert-actions"><button onClick={dismiss}>Remind me tomorrow</button><button onClick={() => { dismiss(); onReview(); }}>Review reorder suggestions</button></div></div></section></div>;
}
