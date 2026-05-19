import dotenv from 'dotenv';
import { query } from './db.js';

dotenv.config();

async function runWorker() {
  try {
    const jobs = await query(`select run_daily_finance_jobs(null, now(), 2, 'http://localhost:5173')`);
    console.log('Daily jobs:', jobs.rows[0]);
  } catch (e) {
    console.log('run_daily_finance_jobs not available or failed:', e.message);
  }

  const pending = await query(`select * from notifications where status='PENDING' order by created_at asc limit 50`);
  for (const n of pending.rows) {
    try {
      console.log('[DEV EMAIL]', n.template_code, n.subject, n.payload);
      await query(`update notifications set status='SENT', sent_at=now(), error_message=null where id=$1`, [n.id]);
    } catch (e) {
      await query(`update notifications set status='FAILED', error_message=$2 where id=$1`, [n.id, e.message]);
    }
  }
  console.log(`Processed ${pending.rows.length} notifications`);
}

runWorker().then(()=>process.exit(0)).catch((e)=>{console.error(e);process.exit(1);});
