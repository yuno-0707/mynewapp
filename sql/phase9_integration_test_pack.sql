-- Phase 9: integration test pack (fixtures + scenario assertions)
-- Purpose: executable SQL smoke/integration checks for phases 1-8

begin;

-- ======================================
-- Test run log table
-- ======================================
create table if not exists test_run_logs (
  id uuid primary key default gen_random_uuid(),
  test_name text not null,
  status text not null check (status in ('PASS', 'FAIL')),
  details text,
  created_at timestamptz not null default now()
);

create or replace function log_test_result(p_test_name text, p_status text, p_details text default null)
returns void
language plpgsql
as $$
begin
  insert into test_run_logs(test_name, status, details)
  values (p_test_name, p_status, p_details);
end;
$$;

-- ======================================
-- Test helper assertion
-- ======================================
create or replace function assert_true(p_test_name text, p_condition boolean, p_details text default null)
returns void
language plpgsql
as $$
begin
  if coalesce(p_condition, false) then
    perform log_test_result(p_test_name, 'PASS', p_details);
  else
    perform log_test_result(p_test_name, 'FAIL', p_details);
    raise exception 'Assertion failed: % (%).', p_test_name, coalesce(p_details, '');
  end if;
end;
$$;

-- ======================================
-- Fixtures
-- ======================================
-- users
insert into users (email, first_name, last_name, is_active, password_reset_required)
values
  ('qa.admin@example.com', 'QA', 'Admin', true, false),
  ('qa.requestor@example.com', 'QA', 'Requestor', true, false),
  ('qa.approver@example.com', 'QA', 'Approver', true, false),
  ('qa.finance@example.com', 'QA', 'Finance', true, false)
on conflict (email) do update set first_name = excluded.first_name;

-- assign roles
insert into user_roles(user_id, role_id)
select u.id, r.id
from users u
join roles r on (
  (u.email = 'qa.admin@example.com' and r.code = 'ADMIN') or
  (u.email = 'qa.requestor@example.com' and r.code = 'REQUESTOR') or
  (u.email = 'qa.approver@example.com' and r.code = 'APPROVER') or
  (u.email = 'qa.finance@example.com' and r.code = 'FINANCE_PROCESSOR')
)
on conflict (user_id, role_id) do nothing;

-- master data
insert into companies(code, name) values ('QA-COMP', 'QA Company') on conflict (code) do nothing;
insert into business_units(code, name) values ('QA-BU', 'QA BU') on conflict (code) do nothing;
insert into clients(code, name, business_unit_id)
select 'QA-CLIENT', 'QA Client', bu.id from business_units bu where bu.code='QA-BU'
on conflict (code) do nothing;
insert into departments(code, name) values ('QA-DEPT', 'QA Department') on conflict (code) do nothing;
insert into project_categories(code, name) values ('QA-PCAT', 'QA Category') on conflict (code) do nothing;
insert into project_types(code, name) values ('QA-PTYPE', 'QA Type') on conflict (code) do nothing;
insert into brands(code, name) values ('QA-BRAND', 'QA Brand') on conflict (code) do nothing;
insert into project_statuses(code, name) values ('QA-PSTAT', 'QA Active') on conflict (code) do nothing;
insert into budget_categories(code, name) values ('QA-BCAT', 'QA Budget Cat') on conflict (code) do nothing;

insert into projects(
  code, name, company_id, client_id, business_unit_id,
  project_category_id, project_type_id, brand_id, project_status_id
)
select
  'QA-PROJ', 'QA Project', c.id, cl.id, bu.id,
  pc.id, pt.id, b.id, ps.id
from companies c
join clients cl on cl.code = 'QA-CLIENT'
join business_units bu on bu.code = 'QA-BU'
join project_categories pc on pc.code = 'QA-PCAT'
join project_types pt on pt.code = 'QA-PTYPE'
join brands b on b.code = 'QA-BRAND'
join project_statuses ps on ps.code = 'QA-PSTAT'
where c.code = 'QA-COMP'
on conflict (code) do nothing;

-- budgets
insert into budgets(
  fiscal_year, request_type, project_id, budget_category_id,
  allocated_amount, consumed_amount, committed_amount, is_active
)
select extract(year from current_date)::int, 'PROJECT', p.id, bc.id, 100000, 0, 0, true
from projects p
join budget_categories bc on bc.code = 'QA-BCAT'
where p.code = 'QA-PROJ'
on conflict do nothing;

-- ======================================
-- Workflows and levels
-- ======================================
insert into approval_workflows(name, scope, request_type, payment_type, is_active)
values
  ('QA Request Workflow', 'REQUEST', 'PROJECT', 'CASH_ADVANCE', true),
  ('QA Liquidation Workflow', 'LIQUIDATION', 'PROJECT', 'CASH_ADVANCE', true),
  ('QA Pre-Approval Workflow', 'PRE_APPROVAL', 'PROJECT', 'CASH_ADVANCE', true),
  ('QA Excess Liquidation Workflow', 'EXCESS_LIQUIDATION', 'PROJECT', 'CASH_ADVANCE', true)
on conflict do nothing;

insert into approval_levels(workflow_id, level_no, approver_user_id, is_active)
select aw.id, 1, u.id, true
from approval_workflows aw
join users u on u.email = 'qa.approver@example.com'
where aw.name in (
  'QA Request Workflow',
  'QA Liquidation Workflow',
  'QA Pre-Approval Workflow',
  'QA Excess Liquidation Workflow'
)
on conflict (workflow_id, level_no) do nothing;

-- ======================================
-- Scenario A: happy path request -> approval -> release -> liquidation -> approval -> close
-- ======================================
do $$
declare
  v_requestor_id uuid;
  v_approver_id uuid;
  v_finance_id uuid;
  v_project_id uuid;
  v_company_id uuid;
  v_client_id uuid;
  v_bu_id uuid;
  v_request_id uuid;
  v_request_no text;
  v_approval_instance_id uuid;
  v_liq_id uuid;
  v_liq_approval_instance_id uuid;
  v_status request_status;
  v_lstatus liquidation_status;
  v_budget_result budget_check_result;
begin
  select id into v_requestor_id from users where email = 'qa.requestor@example.com';
  select id into v_approver_id from users where email = 'qa.approver@example.com';
  select id into v_finance_id from users where email = 'qa.finance@example.com';
  select id, company_id, client_id, business_unit_id
    into v_project_id, v_company_id, v_client_id, v_bu_id
  from projects where code = 'QA-PROJ';

  v_request_no := 'QA-REQ-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS');

  insert into requests(
    request_no, request_type, payment_type, requestor_id,
    company_id, client_id, business_unit_id, project_id,
    status, total_amount, liquidation_due_date
  ) values (
    v_request_no, 'PROJECT', 'CASH_ADVANCE', v_requestor_id,
    v_company_id, v_client_id, v_bu_id, v_project_id,
    'DRAFT', 5000, current_date + 7
  ) returning id into v_request_id;

  insert into request_items(request_id, line_no, category, description, quantity, unit_cost, amount)
  values (v_request_id, 1, 'MANPOWER', 'QA manpower expense', 1, 5000, 5000);

  select budget_result, approval_instance_id
    into v_budget_result, v_approval_instance_id
  from submit_request(v_request_id, v_requestor_id);

  perform assert_true('submit_request_budget_within', v_budget_result = 'WITHIN', 'Expected WITHIN budget result');

  select status into v_status from requests where id = v_request_id;
  perform assert_true('request_status_for_approval', v_status = 'FOR_APPROVAL', 'Request should move to FOR_APPROVAL');

  perform apply_approval_action(v_approval_instance_id, v_approver_id, 'APPROVE', 'QA approve request');

  select status into v_status from requests where id = v_request_id;
  perform assert_true('request_status_approved', v_status = 'APPROVED', 'Request should be APPROVED after final approve');

  perform release_cash_advance(v_request_id, v_finance_id, 'QA release');

  select status into v_status from requests where id = v_request_id;
  perform assert_true('request_status_for_liquidation', v_status = 'FOR_LIQUIDATION', 'Request should move to FOR_LIQUIDATION');

  insert into liquidations(request_id, liquidation_no, submitted_by, status)
  values (v_request_id, 'QA-LIQ-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'), v_requestor_id, 'PENDING')
  returning id into v_liq_id;

  insert into liquidation_items(liquidation_id, request_item_id, line_no, approved_advance_amount, actual_expense_amount, variance_amount, is_excess)
  select v_liq_id, ri.id, 1, 5000, 4500, -500, false
  from request_items ri
  where ri.request_id = v_request_id
  limit 1;

  insert into liquidation_returns(liquidation_id, amount_returned, date_returned, reference_no, notes)
  values (v_liq_id, 500, current_date, 'QA-RETURN-REF', 'QA returned funds');

  select approval_instance_id
    into v_liq_approval_instance_id
  from submit_liquidation(v_liq_id, v_requestor_id, 'QA liquidation submit');

  select status into v_lstatus from liquidations where id = v_liq_id;
  perform assert_true('liquidation_status_for_approval', v_lstatus = 'FOR_APPROVAL', 'Liquidation should be FOR_APPROVAL');

  perform apply_approval_action(v_liq_approval_instance_id, v_approver_id, 'APPROVE', 'QA approve liquidation');

  select status into v_lstatus from liquidations where id = v_liq_id;
  perform assert_true('liquidation_status_approved', v_lstatus = 'APPROVED', 'Liquidation should be APPROVED');

  perform finalize_liquidation_to_request(v_liq_id, v_finance_id, 'QA sync request from liquidation');

  select status into v_status from requests where id = v_request_id;
  perform assert_true('request_status_liquidated', v_status = 'LIQUIDATED', 'Request should be LIQUIDATED when outstanding = 0');
end $$;

-- ======================================
-- Scenario B: pre-approval route (budget exceeded)
-- ======================================
do $$
declare
  v_requestor_id uuid;
  v_project_id uuid;
  v_company_id uuid;
  v_client_id uuid;
  v_bu_id uuid;
  v_request_id uuid;
  v_status request_status;
begin
  select id into v_requestor_id from users where email = 'qa.requestor@example.com';
  select id, company_id, client_id, business_unit_id
    into v_project_id, v_company_id, v_client_id, v_bu_id
  from projects where code = 'QA-PROJ';

  insert into requests(
    request_no, request_type, payment_type, requestor_id,
    company_id, client_id, business_unit_id, project_id,
    status, total_amount, liquidation_due_date
  ) values (
    'QA-REQ-EXCEED-' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS'),
    'PROJECT', 'CASH_ADVANCE', v_requestor_id,
    v_company_id, v_client_id, v_bu_id, v_project_id,
    'DRAFT', 200000, current_date + 7
  ) returning id into v_request_id;

  insert into request_items(request_id, line_no, category, description, quantity, unit_cost, amount)
  values (v_request_id, 1, 'OTHER_REQUEST', 'QA exceed budget item', 1, 200000, 200000);

  perform submit_request(v_request_id, v_requestor_id);

  select status into v_status from requests where id = v_request_id;
  perform assert_true('request_status_for_preapproval', v_status = 'FOR_PRE_APPROVAL', 'Request should route to FOR_PRE_APPROVAL');
end $$;

-- ======================================
-- Scenario C: reporting + scheduler smoke
-- ======================================
do $$
declare
  v_count integer;
  v_jobs jsonb;
begin
  select count(*) into v_count from v_report_aging_outstanding_unliquidated;
  perform assert_true('report_aging_view_available', v_count >= 1, 'Aging report should return at least one row');

  select count(*) into v_count from v_report_unliquidated_summary_per_requestor;
  perform assert_true('report_requestor_summary_available', v_count >= 1, 'Requestor summary should return rows');

  select queue_daily_unliquidated_digest(now()) into v_count;
  perform assert_true('queue_daily_digest_runs', v_count >= 0, 'Daily digest function should execute');

  select queue_pre_overdue_reminders(now(), 2, 'https://qa.local/liquidation') into v_count;
  perform assert_true('queue_pre_overdue_runs', v_count >= 0, 'Pre-overdue function should execute');

  select run_daily_finance_jobs(null, now(), 2, 'https://qa.local/liquidation') into v_jobs;
  perform assert_true('run_daily_finance_jobs_runs', v_jobs is not null, 'Scheduler entrypoint should return JSON payload');
end $$;

commit;

-- Final summary
select status, count(*) as total
from test_run_logs
group by status
order by status;
