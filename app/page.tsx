"use client";
import { FormEvent, useEffect, useMemo, useState } from "react";
import type { Session } from "@supabase/supabase-js";
import { supabase } from "../lib/supabase";

type Product={id:string;name:string;sku:string;category:string;price:number;stock:number;color:string};
type ProductRow={id:string;name:string;sku:string;selling_price:number|string;quantity_on_hand:number|string;categories:{name:string}|null};
const colors=["#dff3e8","#e8efff","#faead8","#f1e8ff","#f3e4da","#dff1f7"];
const peso=new Intl.NumberFormat("en-PH",{style:"currency",currency:"PHP"});

export default function Home(){
 const [session,setSession]=useState<Session|null>(null),[checking,setChecking]=useState(true);
 const [email,setEmail]=useState(""),[password,setPassword]=useState(""),[authError,setAuthError]=useState("");
 const [products,setProducts]=useState<Product[]>([]),[loading,setLoading]=useState(false),[dataError,setDataError]=useState("");
 const [query,setQuery]=useState(""),[cart,setCart]=useState<Record<string,number>>({}),[notice,setNotice]=useState(""),[payment,setPayment]=useState("cash");

 useEffect(()=>{supabase.auth.getSession().then(({data})=>{setSession(data.session);setChecking(false)});const {data}=supabase.auth.onAuthStateChange((_e,s)=>setSession(s));return()=>data.subscription.unsubscribe()},[]);
 useEffect(()=>{if(session)loadProducts()},[session]);
 async function signIn(e:FormEvent){e.preventDefault();setAuthError("");const {error}=await supabase.auth.signInWithPassword({email,password});if(error)setAuthError(error.message)}
 async function loadProducts(){setLoading(true);setDataError("");const {data,error}=await supabase.from("products").select("id,name,sku,selling_price,quantity_on_hand,categories(name)").eq("active",true).order("name");if(error)setDataError(error.message);else setProducts(((data??[]) as unknown as ProductRow[]).map((p,i)=>({id:p.id,name:p.name,sku:p.sku,price:Number(p.selling_price),stock:Number(p.quantity_on_hand),category:p.categories?.name??"Uncategorised",color:colors[i%colors.length]})));setLoading(false)}
 const filtered=products.filter(p=>`${p.name} ${p.sku} ${p.category}`.toLowerCase().includes(query.toLowerCase())),lines=products.filter(p=>cart[p.id]);
 const subtotal=useMemo(()=>lines.reduce((s,p)=>s+p.price*cart[p.id],0),[cart,lines]),vat=subtotal-subtotal/1.12;
 const add=(p:Product)=>{setNotice("");setCart(c=>({...c,[p.id]:Math.min(p.stock,(c[p.id]??0)+1)}))};
 const qty=(id:string,d:number)=>setCart(c=>{const p=products.find(x=>x.id===id),n=Math.min(p?.stock??0,Math.max(0,(c[id]??0)+d)),u={...c};if(!n)delete u[id];else u[id]=n;return u});
 async function complete(){if(!lines.length)return;setLoading(true);setNotice("");const items=lines.map(p=>({product_id:p.id,quantity:cart[p.id]}));const {error}=await supabase.rpc("complete_sale",{p_items:items,p_payment_method:payment,p_customer_id:null});if(error)setNotice(`Error: ${error.message}`);else{setNotice(`Sale completed — ${peso.format(subtotal)}`);setCart({});await loadProducts()}setLoading(false)}

 if(checking)return <main className="auth-shell"><div className="auth-card"><span className="auth-logo">R</span><p>Opening RetailFlow…</p></div></main>;
 if(!session)return <main className="auth-shell"><form className="auth-card" onSubmit={signIn}><span className="auth-logo">R</span><h1>Welcome to RetailFlow</h1><p>Sign in with a user created in your Supabase project.</p><label>Email<input type="email" required value={email} onChange={e=>setEmail(e.target.value)} placeholder="you@store.com"/></label><label>Password<input type="password" required value={password} onChange={e=>setPassword(e.target.value)} placeholder="••••••••"/></label>{authError&&<div className="auth-error">{authError}</div>}<button type="submit">Sign in</button><small>Retail Sales & Inventory · Bohol</small></form></main>;
 return <main className="app-shell">
  <aside className="sidebar"><div className="brand"><span>R</span><div>RetailFlow<small>Sales & Inventory</small></div></div><nav aria-label="Main navigation"><a className="active" href="#pos">▦ <span>Point of Sale</span></a><a href="#dashboard">⌂ <span>Dashboard</span></a><a href="#products">□ <span>Products</span></a><a href="#inventory">↕ <span>Inventory</span></a><a href="#customers">♙ <span>Customers</span></a><a href="#reports">⌁ <span>Reports</span></a></nav><div className="store-card"><span className="status-dot"/>Supabase connected<small>Main Branch · Bohol</small></div><button className="profile" onClick={()=>supabase.auth.signOut()}><span>{session.user.email?.slice(0,2).toUpperCase()}</span><div>{session.user.email}<small>Sign out</small></div><b>↗</b></button></aside>
  <section className="workspace" id="pos"><header><div><p>{new Intl.DateTimeFormat("en-PH",{dateStyle:"full"}).format(new Date())}</p><h1>Point of Sale</h1></div><div className="header-actions"><button aria-label="Refresh products" onClick={loadProducts}>↻</button><button>＋ New customer</button></div></header>
   <div className="pos-grid"><section className="catalog"><label className="search"><span>⌕</span><input value={query} onChange={e=>setQuery(e.target.value)} placeholder="Search product, SKU, or scan barcode…"/><kbd>⌘ K</kbd></label><div className="catalog-heading"><div><h2>Products</h2><p>{loading?"Loading…":`${filtered.length} items available`}</p></div><button>All categories⌄</button></div>
    {dataError&&<div className="setup-warning"><strong>Database setup required</strong><span>{dataError}</span></div>}
    <div className="product-grid">{filtered.map(p=><button className="product-card" onClick={()=>add(p)} key={p.id} disabled={p.stock<=0}><span className="product-art" style={{background:p.color}}>{p.name.split(" ").slice(0,2).map(w=>w[0]).join("")}</span><span className="category">{p.category}</span><strong>{p.name}</strong><small>{p.sku}</small><span className="product-meta"><b>{peso.format(p.price)}</b><em className={p.stock<=8?"low":""}>{p.stock} in stock</em></span></button>)}</div>
    <div className="quick-stats"><div><span>Live products</span><strong>{products.length}</strong><small>From Supabase</small></div><div><span>Cart items</span><strong>{Object.values(cart).reduce((a,b)=>a+b,0)}</strong><small>Current transaction</small></div><div><span>Low stock</span><strong>{products.filter(p=>p.stock<=8).length} items</strong><small>Needs attention</small></div></div>
   </section><aside className="cart-panel"><div className="cart-title"><div><h2>Current sale</h2><p>New transaction</p></div><button onClick={()=>setCart({})}>Clear</button></div><button className="customer-row"><span>＋</span><div><strong>Add customer</strong><small>Optional for this sale</small></div><b>›</b></button><div className="cart-lines">{!lines.length&&<div className="empty-cart"><span>▣</span><strong>Your cart is empty</strong><small>Select a product to begin a sale.</small></div>}{lines.map(p=><div className="cart-line" key={p.id}><span className="mini-art" style={{background:p.color}}>{p.name[0]}</span><div className="line-info"><strong>{p.name}</strong><small>{peso.format(p.price)} each</small><div className="stepper"><button onClick={()=>qty(p.id,-1)}>−</button><b>{cart[p.id]}</b><button onClick={()=>qty(p.id,1)}>＋</button></div></div><b>{peso.format(p.price*cart[p.id])}</b></div>)}</div>
    <div className="totals"><div><span>Subtotal</span><b>{peso.format(subtotal)}</b></div><div><span>VAT included</span><b>{peso.format(vat)}</b></div><div className="grand-total"><span>Total</span><b>{peso.format(subtotal)}</b></div></div>{notice&&<p className={notice.startsWith("Error")?"notice error":"notice"}>{notice}</p>}<button className="checkout" disabled={!lines.length||loading} onClick={complete}><span>{loading?"Processing…":"Complete sale"}</span><b>{peso.format(subtotal)} →</b></button><div className="payment-types">{["cash","card","gcash"].map(x=><button key={x} className={payment===x?"selected":""} onClick={()=>setPayment(x)}>{x==="gcash"?"GCash":x[0].toUpperCase()+x.slice(1)}</button>)}</div>
   </aside></div>
  </section>
 </main>
}
