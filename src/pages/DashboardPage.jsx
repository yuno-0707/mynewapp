import React, { useEffect, useState } from 'react'; import { api } from '../api';
export default function DashboardPage(){const [d,setD]=useState({}); useEffect(()=>{api('/dashboard/kpis').then(setD)},[]); return <div><h2>Dashboard</h2><pre>{JSON.stringify(d,null,2)}</pre></div>;}
