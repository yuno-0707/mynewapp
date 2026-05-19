import React,{useEffect,useState} from 'react'; import { api } from '../api';
export default function CashAdvanceReleasePage({ user }){const [rows,setRows]=useState([]); const load=()=>api('/cash-advances/approved').then(setRows); useEffect(load,[]); const rel=async(id)=>{await api(`/cash-advances/${id}/release`,{method:'POST',body:JSON.stringify({user_id:user.id,remarks:'Released'})});load();};
return <div><h2>Cash Advance Release</h2>{rows.map(r=><div key={r.id}><code>{r.request_no}</code><button onClick={()=>rel(r.id)}>Release</button></div>)}</div>}
