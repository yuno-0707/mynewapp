import { query } from '../db.js';

export async function login(email) {
  const result = await query(
    `select u.id, u.email, u.display_name, array_remove(array_agg(r.code), null) as roles
     from users u
     left join user_roles ur on ur.user_id = u.id
     left join roles r on r.id = ur.role_id
     where u.email = $1 and u.is_active = true
     group by u.id`,
    [email]
  );
  return result.rows[0] || null;
}
