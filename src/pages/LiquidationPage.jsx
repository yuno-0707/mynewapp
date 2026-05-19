import React,{useEffect,useMemo,useState} from 'react'; import { api } from '../api';
export default function LiquidationPage({ user }){
  const [rows,setRows]=useState([]); const [requestId,setRequestId]=useState(''); const [actual,setActual]=useState(''); const [returned,setReturned]=useState('0'); const [reference,setReference]=useState('DEV-REF'); const [msg,setMsg]=useState('');
  const load=()=>api('/liquidations/pending').then(setRows); useEffect(load,[]);
  const grouped = useMemo(()=>rows.reduce((a,r)=>{a[r.request_id]=a[r.request_id]||{request_no:r.request_no,total_amount:r.total_amount,items:[]};a[r.request_id].items.push(r);return a;},{}),[rows]);
  const submit=async()=>{
    const g=grouped[requestId]; if(!g) return;
    const amount = Number(actual || g.total_amount);
    const items = g.items.map((it)=>({request_item_id:it.request_item_id, approved_advance_amount:Number(it.amount), actual_expense_amount:Number((amount/g.items.length).toFixed(2))}));
    await api('/liquidations',{method:'POST',body:JSON.stringify({request_id:requestId,submitted_by:user.id,items,returned_amount:Number(returned),return_reference:reference})});
    setMsg('Liquidation submitted for approval'); load();
  };
  return <div><h2>Liquidation</h2><select value={requestId} onChange={e=>setRequestId(e.target.value)}><option value=''>Select Request</option>{Object.entries(grouped).map(([id,v])=><option key={id} value={id}>{v.request_no} ({v.total_amount})</option>)}</select><input placeholder='Actual Total Expense' value={actual} onChange={e=>setActual(e.target.value)}/><input placeholder='Returned Amount' value={returned} onChange={e=>setReturned(e.target.value)}/><input placeholder='Return Ref / Deposit Slip Ref' value={reference} onChange={e=>setReference(e.target.value)}/><button onClick={submit}>Submit Liquidation</button><p>{msg}</p><pre>{JSON.stringify(grouped[requestId]||{},null,2)}</pre></div>
}
