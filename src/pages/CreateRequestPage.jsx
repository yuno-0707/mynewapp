import React, { useEffect, useMemo, useState } from 'react';
import { api } from '../api';

export default function CreateRequestPage({ user }) {
  const [msg, setMsg] = useState('');
  const [lookup, setLookup] = useState({ projects: [], departments: [], companies: [], clients: [], business_units: [] });
  const [ceItems, setCeItems] = useState([]);
  const [itemAmount, setItemAmount] = useState(1000);
  const [form, setForm] = useState({ request_type:'PROJECT', payment_type:'CASH_ADVANCE', total_amount:1000, liquidation_due_date:'', project_id:'', department_id:'', company_id:'', client_id:'', business_unit_id:'', ce_item_id:'' });

  useEffect(()=>{ api('/lookups/request-form').then(setLookup).catch(()=>{}); },[]);
  useEffect(()=>{
    if(form.request_type==='PROJECT' && form.project_id){ api(`/projects/${form.project_id}/ce-items`).then(setCeItems).catch(()=>setCeItems([])); }
    else setCeItems([]);
  },[form.request_type, form.project_id]);

  const selectedCe = useMemo(()=>ceItems.find(c=>c.id===form.ce_item_id),[ceItems, form.ce_item_id]);

  const submit = async () => {
    try {
      const now = Date.now();
      const req = await api('/requests', { method:'POST', body: JSON.stringify({
        ...form,
        request_no:`WEB-${now}`,
        requestor_id:user.id,
        total_amount:Number(itemAmount),
        items:[{ ce_item_id: form.ce_item_id || null, category:'MANPOWER', description:selectedCe?.description || 'Web item', quantity:1, unit_cost:Number(itemAmount), amount:Number(itemAmount)}]
      })});
      const sub = await api(`/requests/${req.id}/submit`,{method:'POST',body:JSON.stringify({user_id:user.id})});
      setMsg(`Request submitted. Status: ${sub.final_status}. Budget: ${sub.budget_result}`);
    } catch (e) { setMsg(e.message); }
  };

  return <div><h2>Create Request</h2>
    <select value={form.request_type} onChange={e=>setForm({...form,request_type:e.target.value})}><option>PROJECT</option><option>OPEX</option><option>CAPEX</option></select>
    <select value={form.payment_type} onChange={e=>setForm({...form,payment_type:e.target.value})}><option>CASH_ADVANCE</option><option>DIRECT</option></select>
    <select value={form.company_id} onChange={e=>setForm({...form,company_id:e.target.value})}><option value=''>Company</option>{lookup.companies.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
    <select value={form.client_id} onChange={e=>setForm({...form,client_id:e.target.value})}><option value=''>Client</option>{lookup.clients.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
    <select value={form.business_unit_id} onChange={e=>setForm({...form,business_unit_id:e.target.value})}><option value=''>Business Unit</option>{lookup.business_units.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
    {form.request_type==='PROJECT' ? <select value={form.project_id} onChange={e=>setForm({...form,project_id:e.target.value})}><option value=''>Project</option>{lookup.projects.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>
      : <select value={form.department_id} onChange={e=>setForm({...form,department_id:e.target.value})}><option value=''>Department</option>{lookup.departments.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select>}
    {form.request_type==='PROJECT' && <select value={form.ce_item_id} onChange={e=>setForm({...form,ce_item_id:e.target.value})}><option value=''>CE Item</option>{ceItems.map(x=><option key={x.id} value={x.id}>{x.ce_code} #{x.line_no} {x.description}</option>)}</select>}
    <input placeholder='Due Date YYYY-MM-DD' value={form.liquidation_due_date} onChange={e=>setForm({...form,liquidation_due_date:e.target.value})}/>
    <input type='number' value={itemAmount} onChange={e=>setItemAmount(e.target.value)}/>
    <button onClick={submit}>Create + Submit</button><p>{msg}</p></div>;
}
