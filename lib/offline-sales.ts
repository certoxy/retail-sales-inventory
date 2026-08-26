export type OfflineSaleItem={product_id:string;name:string;sku:string;quantity:number;unit_price:number};
export type OfflineSale={id:string;branch_id:string;branch_name:string;shift_id:string;cashier_id:string;created_at:string;items:OfflineSaleItem[];total:number;status:"pending"|"syncing"|"synced"|"failed";attempts:number;last_error?:string;sale_id?:string;receipt_number?:number;synced_at?:string};

const DB="retailflow-offline",STORE="sales";
function database():Promise<IDBDatabase>{return new Promise((resolve,reject)=>{const request=indexedDB.open(DB,1);request.onupgradeneeded=()=>{if(!request.result.objectStoreNames.contains(STORE))request.result.createObjectStore(STORE,{keyPath:"id"})};request.onsuccess=()=>resolve(request.result);request.onerror=()=>reject(request.error)})}
export async function saveOfflineSale(sale:OfflineSale){const db=await database();await new Promise<void>((resolve,reject)=>{const tx=db.transaction(STORE,"readwrite");tx.objectStore(STORE).put(sale);tx.oncomplete=()=>resolve();tx.onerror=()=>reject(tx.error)});db.close()}
export async function listOfflineSales():Promise<OfflineSale[]>{const db=await database();const rows=await new Promise<OfflineSale[]>((resolve,reject)=>{const request=db.transaction(STORE).objectStore(STORE).getAll();request.onsuccess=()=>resolve(request.result as OfflineSale[]);request.onerror=()=>reject(request.error)});db.close();return rows.sort((a,b)=>b.created_at.localeCompare(a.created_at))}
export async function pendingOfflineSales(){return (await listOfflineSales()).filter(x=>x.status==="pending"||x.status==="failed")}
export function cacheCatalogue(branchId:string,products:unknown){localStorage.setItem(`retailflow-catalogue:${branchId}`,JSON.stringify({saved_at:new Date().toISOString(),products}))}
export function readCachedCatalogue<T>(branchId:string):T[]{try{return JSON.parse(localStorage.getItem(`retailflow-catalogue:${branchId}`)||"{}").products??[]}catch{return[]}}
