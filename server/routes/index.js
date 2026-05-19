import express from 'express';
import { query } from '../db.js';
import { ok, fail } from '../services/response.js';
import { login } from '../services/auth.js';

const router = express.Router();

router.post('/login', async (req, res) => {
  try {
    const { email } = req.body;
    if (!email) return fail(res, 'Email is required', 'VALIDATION_ERROR', 400);
    const user = await login(email);
    if (!user) return fail(res, 'Invalid credentials', 'AUTH_FAILED', 401);
    return ok(res, user);
  } catch (e) { return fail(res, e.message); }
});

router.get('/dashboard/kpis', async (_req, res) => {
  try {
    const r = await query('select * from v_dashboard_kpis limit 1');
    return ok(res, r.rows[0] || {});
  } catch (e) { return fail(res, e.message); }
});

router.post('/requests', async (req, res) => {
  try {
    const { request_no, request_type, payment_type, requestor_id, project_id, department_id, company_id, client_id, business_unit_id, total_amount, liquidation_due_date, items = [] } = req.body;
    const r = await query(
      `insert into requests(request_no, request_type, payment_type, requestor_id, project_id, department_id, company_id, client_id, business_unit_id, total_amount, liquidation_due_date, status)
       values($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,'DRAFT') returning *`,
      [request_no, request_type, payment_type, requestor_id, project_id || null, department_id || null, company_id || null, client_id || null, business_unit_id || null, total_amount, liquidation_due_date || null]
    );
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      await query(
        `insert into request_items(request_id, line_no, category, description, quantity, unit_cost, amount)
         values($1,$2,$3,$4,$5,$6,$7)`,
        [r.rows[0].id, i + 1, it.category, it.description, it.quantity, it.unit_cost, it.amount]
      );
    }
    return ok(res, r.rows[0]);
  } catch (e) { return fail(res, e.message, 'CREATE_REQUEST_ERROR', 400); }
});

router.post('/requests/:id/submit', async (req, res) => {
  try { const r = await query('select * from submit_request($1,$2)', [req.params.id, req.body.user_id]); return ok(res, r.rows[0]); }
  catch (e) { return fail(res, e.message, 'SUBMIT_REQUEST_ERROR', 400); }
});

router.get('/approvals/inbox', async (_req, res) => {
  try {
    const r = await query(`select ai.id as approval_instance_id, ai.entity_type, ai.entity_id, ai.current_level_no, ai.status,
      req.request_no, req.total_amount, req.status as request_status
      from approval_instances ai
      left join requests req on req.id = ai.entity_id and ai.entity_type='REQUEST'
      where ai.status='PENDING' order by ai.started_at desc`);
    return ok(res, r.rows);
  } catch (e) { return fail(res, e.message); }
});

router.post('/approvals/:id/action', async (req, res) => {
  try { const r = await query('select * from apply_approval_action($1,$2,$3,$4)', [req.params.id, req.body.user_id, req.body.action, req.body.remarks || null]); return ok(res, r.rows[0]); }
  catch (e) { return fail(res, e.message, 'APPROVAL_ACTION_ERROR', 400); }
});

router.get('/cash-advances/approved', async (_req, res) => {
  try { const r = await query(`select * from requests where payment_type='CASH_ADVANCE' and status='APPROVED' order by created_at desc`); return ok(res, r.rows); }
  catch (e) { return fail(res, e.message); }
});

router.post('/cash-advances/:id/release', async (req, res) => {
  try { const r = await query('select * from release_cash_advance($1,$2,$3)', [req.params.id, req.body.user_id, req.body.remarks || null]); return ok(res, r.rows[0]); }
  catch (e) { return fail(res, e.message, 'RELEASE_ERROR', 400); }
});

router.get('/liquidations/pending', async (_req, res) => {
  try {
    const r = await query(`select r.id as request_id, r.request_no, r.total_amount from requests r where r.payment_type='CASH_ADVANCE' and r.status='FOR_LIQUIDATION'`);
    return ok(res, r.rows);
  } catch (e) { return fail(res, e.message); }
});

router.post('/liquidations', async (req, res) => {
  try {
    const { request_id, submitted_by, items = [], returned_amount = 0, return_reference = '' } = req.body;
    const liq = await query(`insert into liquidations(request_id, liquidation_no, submitted_by, status) values($1,$2,$3,'PENDING') returning *`, [request_id, `LIQ-${Date.now()}`, submitted_by]);
    for (let i = 0; i < items.length; i++) {
      const it = items[i];
      await query(`insert into liquidation_items(liquidation_id, request_item_id, line_no, approved_advance_amount, actual_expense_amount, variance_amount, is_excess)
      values($1,$2,$3,$4,$5,$6,$7)`, [liq.rows[0].id, it.request_item_id, i + 1, it.approved_advance_amount, it.actual_expense_amount, it.actual_expense_amount - it.approved_advance_amount, it.actual_expense_amount > it.approved_advance_amount]);
    }
    if (returned_amount > 0) {
      await query(`insert into liquidation_returns(liquidation_id, amount_returned, date_returned, reference_no) values($1,$2,current_date,$3)`, [liq.rows[0].id, returned_amount, return_reference || 'DEV-REF']);
    }
    const s = await query('select * from submit_liquidation($1,$2,$3)', [liq.rows[0].id, submitted_by, 'Submitted via API']);
    return ok(res, { liquidation: liq.rows[0], submit_result: s.rows[0] });
  } catch (e) { return fail(res, e.message, 'LIQUIDATION_SUBMIT_ERROR', 400); }
});

router.post('/liquidations/:id/finalize', async (req, res) => {
  try { const r = await query('select * from finalize_liquidation_to_request($1,$2,$3)', [req.params.id, req.body.user_id, req.body.remarks || null]); return ok(res, r.rows[0]); }
  catch (e) { return fail(res, e.message, 'FINALIZE_LIQUIDATION_ERROR', 400); }
});

router.get('/reports/:name', async (req, res) => {
  const map = {
    aging: 'v_report_aging_outstanding_unliquidated',
    project_totals: 'v_report_total_requests_per_project',
    requestor_summary: 'v_report_unliquidated_summary_per_requestor',
    overdue: "(select * from v_report_aging_outstanding_unliquidated where due_date < current_date and outstanding_amount > 0)",
    data_quality: 'v_data_quality_issues'
  };
  const target = map[req.params.name];
  if (!target) return fail(res, 'Unknown report', 'NOT_FOUND', 404);
  try { const r = await query(`select * from ${target} limit 500`); return ok(res, r.rows); }
  catch (e) { return fail(res, e.message); }
});

router.get('/masterlists/:table', async (req, res) => {
  const allowed = ['companies', 'departments', 'projects', 'business_units', 'clients'];
  if (!allowed.includes(req.params.table)) return fail(res, 'Table not allowed', 'FORBIDDEN', 403);
  try { const r = await query(`select * from ${req.params.table} order by created_at desc limit 200`); return ok(res, r.rows); }
  catch (e) { return fail(res, e.message); }
});

router.post('/masterlists/:table', async (req, res) => {
  const allowed = ['companies', 'departments', 'business_units', 'clients'];
  if (!allowed.includes(req.params.table)) return fail(res, 'Table not allowed', 'FORBIDDEN', 403);
  try {
    const { code, name } = req.body;
    const r = await query(`insert into ${req.params.table}(code,name) values($1,$2) returning *`, [code, name]);
    return ok(res, r.rows[0]);
  } catch (e) { return fail(res, e.message, 'MASTERLIST_CREATE_ERROR', 400); }
});

router.patch('/masterlists/:table/:id', async (req, res) => {
  const allowed = ['companies', 'departments', 'business_units', 'clients'];
  if (!allowed.includes(req.params.table)) return fail(res, 'Table not allowed', 'FORBIDDEN', 403);
  try {
    const { name, is_active, is_archived } = req.body;
    const r = await query(`update ${req.params.table} set name=coalesce($1,name), is_active=coalesce($2,is_active), is_archived=coalesce($3,is_archived) where id=$4 returning *`, [name ?? null, is_active ?? null, is_archived ?? null, req.params.id]);
    return ok(res, r.rows[0]);
  } catch (e) { return fail(res, e.message, 'MASTERLIST_UPDATE_ERROR', 400); }
});

router.get('/users', async (_req, res) => {
  try {
    const r = await query(`select u.*, array_remove(array_agg(r.code), null) as roles
      from users u
      left join user_roles ur on ur.user_id=u.id
      left join roles r on r.id=ur.role_id
      group by u.id order by u.created_at desc`);
    return ok(res, r.rows);
  } catch (e) { return fail(res, e.message); }
});

router.post('/users', async (req, res) => {
  try {
    const { email, first_name, last_name, role_code } = req.body;
    const u = await query(`insert into users(email, first_name, last_name, password_reset_required) values($1,$2,$3,true) returning *`, [email, first_name, last_name]);
    if (role_code) {
      await query(`insert into user_roles(user_id, role_id) select $1, id from roles where code=$2`, [u.rows[0].id, role_code]);
    }
    return ok(res, u.rows[0]);
  } catch (e) { return fail(res, e.message, 'USER_CREATE_ERROR', 400); }
});

router.patch('/users/:id', async (req, res) => {
  try {
    const { is_active, role_code } = req.body;
    const u = await query(`update users set is_active=coalesce($1,is_active) where id=$2 returning *`, [is_active ?? null, req.params.id]);
    if (role_code) {
      await query(`delete from user_roles where user_id=$1`, [req.params.id]);
      await query(`insert into user_roles(user_id, role_id) select $1, id from roles where code=$2`, [req.params.id, role_code]);
    }
    return ok(res, u.rows[0]);
  } catch (e) { return fail(res, e.message, 'USER_UPDATE_ERROR', 400); }
});

export default router;
