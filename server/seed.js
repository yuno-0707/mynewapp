import dotenv from 'dotenv';
import { query } from './db.js';

dotenv.config();

async function run() {
  await query(`insert into users(email, first_name, last_name, is_active, password_reset_required)
    values
    ('admin@rcams.local','Admin','User',true,false),
    ('requestor@rcams.local','Requestor','User',true,false),
    ('approver@rcams.local','Approver','User',true,false),
    ('finance@rcams.local','Finance','User',true,false)
    on conflict (email) do nothing`);

  await query(`insert into user_roles(user_id, role_id)
    select u.id, r.id from users u join roles r on
    (u.email='admin@rcams.local' and r.code='ADMIN') or
    (u.email='requestor@rcams.local' and r.code='REQUESTOR') or
    (u.email='approver@rcams.local' and r.code='APPROVER') or
    (u.email='finance@rcams.local' and r.code='FINANCE_PROCESSOR')
    on conflict do nothing`);

  console.log('Seed complete');
  process.exit(0);
}
run().catch((e)=>{console.error(e);process.exit(1);});
