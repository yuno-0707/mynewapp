import React,{useEffect,useState} from 'react';
import LoginPage from './pages/LoginPage'; import DashboardPage from './pages/DashboardPage'; import CreateRequestPage from './pages/CreateRequestPage'; import ApprovalInboxPage from './pages/ApprovalInboxPage'; import CashAdvanceReleasePage from './pages/CashAdvanceReleasePage'; import LiquidationPage from './pages/LiquidationPage'; import ReportsPage from './pages/ReportsPage'; import AdminMasterlistPage from './pages/AdminMasterlistPage'; import AdminUsersPage from './pages/AdminUsersPage'; import Nav from './components/Nav';

export default function App(){
  const [user,setUser]=useState(null); const [page,setPage]=useState('Dashboard');
  useEffect(()=>{const s=localStorage.getItem('rcams_user'); if(s) setUser(JSON.parse(s));},[]);
  const onLogin=(u)=>{setUser(u); localStorage.setItem('rcams_user', JSON.stringify(u));};
  const logout=()=>{setUser(null); localStorage.removeItem('rcams_user');};
  if(!user) return <LoginPage onLogin={onLogin}/>;
  return <div><h1>RCAMS MVP</h1><p>{user.display_name} ({(user.roles||[]).join(',')}) <button onClick={logout}>Logout</button></p><Nav setPage={setPage}/>{page==='Dashboard'&&<DashboardPage/>}{page==='Create Request'&&<CreateRequestPage user={user}/>}{page==='Approval Inbox'&&<ApprovalInboxPage user={user}/>}{page==='Cash Advance Release'&&<CashAdvanceReleasePage user={user}/>}{page==='Liquidation'&&<LiquidationPage user={user}/>}{page==='Reports'&&<ReportsPage/>}{page==='Admin Masterlist'&&<AdminMasterlistPage/>}{page==='Admin Users'&&<AdminUsersPage/>}</div>
}
