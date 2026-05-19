import React from 'react';
export default function Nav({ setPage }) {
  const links = ['Dashboard','Create Request','Approval Inbox','Cash Advance Release','Liquidation','Reports','Admin Masterlist','Admin Users'];
  return <div className='nav'>{links.map(l=><button key={l} onClick={()=>setPage(l)}>{l}</button>)}</div>;
}
