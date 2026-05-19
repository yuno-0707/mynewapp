import React, { useState } from 'react';
import { api } from '../api';
export default function LoginPage({ onLogin }) {
  const [email, setEmail] = useState('admin@rcams.local');
  const submit = async () => { const u = await api('/login', { method:'POST', body: JSON.stringify({ email }) }); onLogin(u); };
  return <div><h2>Login</h2><input value={email} onChange={e=>setEmail(e.target.value)} /><button onClick={submit}>Login</button></div>;
}
