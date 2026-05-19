const API = 'http://localhost:3001/api';
export async function api(path, opts = {}) {
  const r = await fetch(`${API}${path}`, { headers: { 'Content-Type': 'application/json' }, ...opts });
  const j = await r.json();
  if (!j.success) throw new Error(j.error?.message || 'API Error');
  return j.data;
}
