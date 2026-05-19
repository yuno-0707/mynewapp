-- Phase 8: quality assurance, release readiness, and migration bookkeeping
-- Requires: schema + phase2..phase7

-- ======================================
-- Migration bookkeeping table
-- ======================================
create table if not exists migration_runs (
  id uuid primary key default gen_random_uuid(),
  migration_code text unique not null,
  description text,
  executed_at timestamptz not null default now(),
  executed_by text,
  checksum text,
  status text not null default 'SUCCESS' check (status in ('SUCCESS', 'FAILED')),
  details jsonb
);

-- ======================================
-- Data quality checks view (for admin QA screen)
-- ======================================
create or replace view v_data_quality_issues as
select 'REQUEST_NEGATIVE_TOTAL' as issue_code,
       r.id::text as entity_id,
       r.request_no as entity_ref,
       'Request total amount is negative' as issue_message,
       now() as detected_at
from requests r
where r.total_amount < 0

union all

select 'REQUEST_MISSING_LINKAGE' as issue_code,
       r.id::text,
       r.request_no,
       'Request missing project/department based on request_type',
       now()
from requests r
where (
  (r.request_type = 'PROJECT' and r.project_id is null)
  or (r.request_type in ('OPEX', 'CAPEX') and r.department_id is null)
)

union all

select 'CA_MISSING_DUE_DATE' as issue_code,
       r.id::text,
       r.request_no,
       'Cash advance request missing liquidation due date',
       now()
from requests r
where r.payment_type = 'CASH_ADVANCE'
  and r.liquidation_due_date is null

union all

select 'LIQ_OVERDUE_WITHOUT_STATUS' as issue_code,
       l.id::text,
       l.liquidation_no,
       'Liquidation is overdue but not marked OVERDUE',
       now()
from liquidations l
join requests r on r.id = l.request_id
where r.payment_type = 'CASH_ADVANCE'
  and r.liquidation_due_date < current_date
  and greatest(r.total_amount - coalesce(l.total_actual_expense,0) - coalesce(l.total_returned_amount,0), 0) > 0
  and l.status <> 'OVERDUE';

-- ======================================
-- Health summary view for operations dashboard
-- ======================================
create or replace view v_system_health_summary as
select
  (select count(*) from migration_runs where status = 'FAILED')::bigint as failed_migration_runs,
  (select count(*) from v_data_quality_issues)::bigint as open_data_quality_issues,
  (select count(*) from notifications where status = 'FAILED')::bigint as failed_notifications,
  (select count(*) from approval_instances where status = 'PENDING')::bigint as pending_approval_instances,
  now() as generated_at;

-- ======================================
-- QA helper: run business-rule assertions
-- Returns failures as rows (empty result = pass)
-- ======================================
create or replace function fn_assert_business_rules()
returns table (
  check_name text,
  result text,
  details text
)
language plpgsql
as $$
begin
  if exists (select 1 from requests where total_amount < 0) then
    return query select 'requests_non_negative_total', 'FAIL', 'One or more requests have negative total_amount';
  else
    return query select 'requests_non_negative_total', 'PASS', 'All requests have non-negative total_amount';
  end if;

  if exists (
    select 1
    from requests
    where payment_type = 'CASH_ADVANCE'
      and liquidation_due_date is null
  ) then
    return query select 'cash_advance_due_date_required', 'FAIL', 'Cash advance request without due date found';
  else
    return query select 'cash_advance_due_date_required', 'PASS', 'All cash advance requests have due dates';
  end if;

  if exists (
    select 1
    from approval_levels
    where approver_role_id is null and approver_user_id is null
  ) then
    return query select 'approval_level_assignee_required', 'FAIL', 'Approval level without role/user assignee found';
  else
    return query select 'approval_level_assignee_required', 'PASS', 'All approval levels have assignees';
  end if;

  if exists (
    select 1
    from liquidations l
    join requests r on r.id = l.request_id
    where r.payment_type = 'CASH_ADVANCE'
      and l.status = 'APPROVED'
      and greatest(r.total_amount - coalesce(l.total_actual_expense,0) - coalesce(l.total_returned_amount,0),0) > 0
      and r.status = 'LIQUIDATED'
  ) then
    return query select 'approved_liquidation_request_sync', 'FAIL', 'Request marked LIQUIDATED but outstanding still > 0';
  else
    return query select 'approved_liquidation_request_sync', 'PASS', 'No request/liquidation sync violations found';
  end if;
end;
$$;

-- ======================================
-- Utility: record successful migration execution
-- ======================================
create or replace function record_migration_run(
  p_migration_code text,
  p_description text default null,
  p_executed_by text default current_user,
  p_checksum text default null,
  p_status text default 'SUCCESS',
  p_details jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
as $$
declare
  v_id uuid;
begin
  insert into migration_runs(
    migration_code,
    description,
    executed_by,
    checksum,
    status,
    details
  )
  values (
    p_migration_code,
    p_description,
    p_executed_by,
    p_checksum,
    p_status,
    p_details
  )
  on conflict (migration_code) do update
  set description = excluded.description,
      executed_at = now(),
      executed_by = excluded.executed_by,
      checksum = excluded.checksum,
      status = excluded.status,
      details = excluded.details
  returning id into v_id;

  return v_id;
end;
$$;

-- ======================================
-- Mark this migration as applied (optional call)
-- ======================================
select record_migration_run(
  'phase8_quality_assurance_and_release',
  'Adds migration bookkeeping, data quality views, system health summary, and QA assertions',
  current_user,
  null,
  'SUCCESS',
  jsonb_build_object('phase', 8)
);
