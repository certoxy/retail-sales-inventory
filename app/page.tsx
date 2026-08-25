"use client";
import { useMemo, useState } from "react";

type Product={id:number;name:string;sku:string;category:string;price:number;stock:number;color:string};
const products:Product[]=[
{id:1,name:"Premium Rice 5 kg",sku:"GRO-001",category:"Grocery",price:295,stock:24,color:"#dff3e8"},
{id:2,name:"Fresh Milk 1 L",sku:"DAI-014",category:"Dairy",price:105,stock:8,color:"#e8efff"},
{id:3,name:"Whole Wheat Bread",sku:"BAK-007",category:"Bakery",price:78,stock:15,color:"#faead8"},
{id:4,name:"Laundry Detergent",sku:"HOM-022",category:"Household",price:189,stock:5,color:"#f1e8ff"},
{id:5,name:"Ground Coffee 250 g",sku:"BEV-031",category:"Beverages",price:245,stock:12,color:"#f3e4da"},
{id:6,name:"Mineral Water 1 L",sku:"BEV-003",category:"Beverages",price:35,stock:42,color:"#dff1f7"},
];
const peso=new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"});

export default function Home(){
 const [query,setQuery]=useState(""); const [cart,setCart]=useState<Record<number,number>>({1:1,3:2}); const [notice,setNotice]=useState("");
 const filtered=products.filter(p=>`${p.name} ${p.sku} ${p.category}`.toLowerCase().includes(query.toLowerCase()));
 const lines=products.filter(p=>cart[p.id]);
 const subtotal=useMemo(()=>lines.reduce((sum,p)=>sum+p.price*cart[p.id],0),[cart,lines]); const vat=subtotal-subtotal/1.12;
 const add=(id:number)=>{setNotice("");setCart(c=>({...c,[id]:(c[id]??0)+1}))};
 const qty=(id:number,d:number)=>setCart(c=>{const n=Math.max(0,(c[id]??0)+d),u={...c};if(n===0)delete u[id];else u[id]=n;return u});
 const complete=()=>{if(!lines.length)return;setNotice(`Sale completed — ${peso.format(subtotal)}`);setCart({})};
 return <main className="app-shell">
  <aside className="sidebar">
   <div className="brand"><span>R</span><div>RetailFlow<small>Sales & Inventory</small></div></div>
   <nav aria-label="Main navigation"><a className="active" href="#pos">▦ <span>Point of Sale</span></a><a href="#dashboard">⌂ <span>Dashboard</span></a><a href="#products">□ <span>Products</span></a><a href="#inventory">↕ <span>Inventory</span></a><a href="#customers">♙ <span>Customers</span></a><a href="#reports">⌁ <span>Reports</span></a></nav>
   <div className="store-card"><span className="status-dot"/>Store is open<small>Main Branch · Bohol</small></div>
   <button className="profile"><span>GM</span><div>Glenn M.<small>Administrator</small></div><b>⋮</b></button>
  </aside>
  <section className="workspace" id="pos">
   <header><div><p>Tuesday, 25 August</p><h1>Point of Sale</h1></div><div className="header-actions"><button aria-label="Notifications">♢<i/></button><button>＋ New customer</button></div></header>
   <div className="pos-grid"><section className="catalog">
    <label className="search"><span>⌕</span><input value={query} onChange={e=>setQuery(e.target.value)} placeholder="Search product, SKU, or scan barcode…"/><kbd>⌘ K</kbd></label>
    <div className="catalog-heading"><div><h2>Products</h2><p>{filtered.length} items available</p></div><button>All categories⌄</button></div>
    <div className="product-grid">{filtered.map(p=><button className="product-card" onClick={()=>add(p.id)} key={p.id}><span className="product-art" style={{background:p.color}}>{p.name.split(" ").slice(0,2).map(w=>w[0]).join("")}</span><span className="category">{p.category}</span><strong>{p.name}</strong><small>{p.sku}</small><span className="product-meta"><b>{peso.format(p.price)}</b><em className={p.stock<=8?"low":""}>{p.stock} in stock</em></span></button>)}</div>
    <div className="quick-stats"><div><span>Today’s sales</span><strong>₱18,420.00</strong><small>↑ 12.5% from yesterday</small></div><div><span>Transactions</span><strong>47</strong><small>Average ₱391.91</small></div><div><span>Low stock</span><strong>6 items</strong><small>Needs attention</small></div></div>
   </section><aside className="cart-panel">
    <div className="cart-title"><div><h2>Current sale</h2><p>Transaction #0048</p></div><button onClick={()=>setCart({})}>Clear</button></div>
    <button className="customer-row"><span>＋</span><div><strong>Add customer</strong><small>Optional for this sale</small></div><b>›</b></button>
    <div className="cart-lines">{lines.length===0&&<div className="empty-cart"><span>▣</span><strong>Your cart is empty</strong><small>Select a product to begin a sale.</small></div>}{lines.map(p=><div className="cart-line" key={p.id}><span className="mini-art" style={{background:p.color}}>{p.name[0]}</span><div className="line-info"><strong>{p.name}</strong><small>{peso.format(p.price)} each</small><div className="stepper"><button onClick={()=>qty(p.id,-1)}>−</button><b>{cart[p.id]}</b><button onClick={()=>qty(p.id,1)}>＋</button></div></div><b>{peso.format(p.price*cart[p.id])}</b></div>)}</div>
    <div className="totals"><div><span>Subtotal</span><b>{peso.format(subtotal)}</b></div><div><span>VAT included</span><b>{peso.format(vat)}</b></div><div className="grand-total"><span>Total</span><b>{peso.format(subtotal)}</b></div></div>
    {notice&&<p className="notice">✓ {notice}</p>}<button className="checkout" disabled={!lines.length} onClick={complete}><span>Complete sale</span><b>{peso.format(subtotal)} →</b></button><div className="payment-types"><span>Cash</span><span>Card</span><span>GCash</span></div>
   </aside></div>
  </section>
 </main>
}
