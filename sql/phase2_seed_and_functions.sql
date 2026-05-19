-- Phase 2: seed data + RBAC seed + core workflow functions
-- Requires: sql/schema.sql already applied

begin;

-- =========================
-- Seed roles
-- =========================
insert into roles (code, name, description) values
  ('ADMIN', 'Admin', 'Full system access'),
  ('REQUESTOR', 'Requestor', 'Creates and tracks requests/liquidations'),
  ('APPROVER', 'Approver', 'Approves/rejects/returns requests'),
  ('FINANCE_PROCESSOR', 'Finance Processor', 'Releases CA and processes liquidation'),
  ('FINANCE_REVIEWER', 'Finance Reviewer', 'Reviews finance transactions and reports'),
  ('VIEWER', 'Viewer', 'Read-only access')
on conflict (code) do update
set name = excluded.name,
    description = excluded.description,
    is_active = true;

-- =========================
-- Seed permissions
-- =========================
insert into permissions (code, name, description) values
  ('request.create', 'Create Request', 'Create new requisition requests'),
  ('request.submit', 'Submit Request', 'Submit drafted requests'),
  ('request.read', 'View Requests', 'View request records'),
  ('request.update', 'Update Request', 'Edit draft/returned requests'),
  ('approval.act', 'Act on Approval', 'Approve/reject/return pending approvals'),
  ('cash_advance.release', 'Release Cash Advance', 'Release approved cash advances'),
  ('liquidation.submit', 'Submit Liquidation', 'Submit liquidation transactions'),
  ('budget.manage', 'Manage Budget', 'Create/update budget entries'),
  ('masterlist.manage', 'Manage Masterlists', 'Create/update/archive masterlists'),
  ('user.manage', 'Manage Users', 'Create/activate/deactivate users/roles'),
  ('report.read', 'View Reports', 'Read and export reports'),
  ('audit.read', 'View Audit Logs', 'Read audit and status logs')
on conflict (code) do update
set name = excluded.name,
    description = excluded.description;

-- =========================
-- Role-Permission mapping
-- =========================
with rp(role_code, permission_code) as (
  values
    -- ADMIN
    ('ADMIN', 'request.create'), ('ADMIN', 'request.submit'), ('ADMIN', 'request.read'), ('ADMIN', 'request.update'),
    ('ADMIN', 'approval.act'), ('ADMIN', 'cash_advance.release'), ('ADMIN', 'liquidation.submit'),
    ('ADMIN', 'budget.manage'), ('ADMIN', 'masterlist.manage'), ('ADMIN', 'user.manage'),
    ('ADMIN', 'report.read'), ('ADMIN', 'audit.read'),

    -- REQUESTOR
    ('REQUESTOR', 'request.create'), ('REQUESTOR', 'request.submit'), ('REQUESTOR', 'request.read'),
    ('REQUESTOR', 'request.update'), ('REQUESTOR', 'liquidation.submit'), ('REQUESTOR', 'report.read'),

    -- APPROVER
    ('APPROVER', 'request.read'), ('APPROVER', 'approval.act'), ('APPROVER', 'report.read'),

    -- FINANCE PROCESSOR
    ('FINANCE_PROCESSOR', 'request.read'), ('FINANCE_PROCESSOR', 'cash_advance.release'),
    ('FINANCE_PROCESSOR', 'liquidation.submit'), ('FINANCE_PROCESSOR', 'report.read'),

    -- FINANCE REVIEWER
    ('FINANCE_REVIEWER', 'request.read'), ('FINANCE_REVIEWER', 'approval.act'),
    ('FINANCE_REVIEWER', 'budget.manage'), ('FINANCE_REVIEWER', 'report.read'), ('FINANCE_REVIEWER', 'audit.read'),

    -- VIEWER
    ('VIEWER', 'request.read'), ('VIEWER', 'report.read')
)
insert into role_permissions(role_id, permission_id)
select r.id, p.id
from rp
join roles r on r.code = rp.role_code
join permissions p on p.code = rp.permission_code
on conflict (role_id, permission_id) do nothing;

-- =========================
-- Minimal masterlist seed
-- =========================
insert into companies(code, name) values
  ('COMP-001', 'Default Company')
on conflict (code) do nothing;

insert into business_units(code, name) values
  ('BU-001', 'Default BU')
on conflict (code) do nothing;

insert into clients(code, name, business_unit_id)
select 'CLIENT-001', 'Default Client', bu.id
from business_units bu
where bu.code = 'BU-001'
on conflict (code) do nothing;

insert into departments(code, name) values
  ('DEPT-OPS', 'Operations'),
  ('DEPT-FIN', 'Finance')
on conflict (code) do nothing;

insert into project_categories(code, name) values
  ('PCAT-001', 'General Project Category')
on conflict (code) do nothing;

insert into project_types(code, name) values
  ('PTYPE-001', 'General Project Type')
on conflict (code) do nothing;

insert into brands(code, name) values
  ('BRAND-001', 'General Brand')
on conflict (code) do nothing;

insert into project_statuses(code, name) values
  ('PSTAT-ACT', 'Active')
on conflict (code) do nothing;

insert into budget_categories(code, name) values
  ('BCAT-MP', 'Manpower'),
  ('BCAT-OTH', 'Other Request')
on conflict (code) do nothing;

commit;

-- ======================================
-- Utility function: get available budget
-- ======================================
create or replace function fn_budget_available(p_budget_id uuid)
returns numeric(14,2)
language sql
stable
as $$
  select greatest(allocated_amount - consumed_amount - committed_amount, 0)::numeric(14,2)
  from budgets
  where id = p_budget_id;
$$;

-- ======================================
-- Core function: run budget check
-- ======================================
create or replace function run_budget_check(p_request_id uuid)
returns table (
  request_id uuid,
  request_total numeric(14,2),
  matched_budget_id uuid,
  available_budget numeric(14,2),
  budget_result budget_check_result,
  requires_preapproval boolean
)
language plpgsql
as $$
declare
  v_request requests%rowtype;
  v_budget_id uuid;
  v_available numeric(14,2);
begin
  select * into v_request
  from requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Request not found: %', p_request_id;
  end if;

  if v_request.request_type = 'PROJECT' then
    select b.id into v_budget_id
    from budgets b
    where b.project_id = v_request.project_id
      and b.request_type = v_request.request_type
      and b.is_active = true
    order by b.created_at desc
    limit 1;
  else
    select b.id into v_budget_id
    from budgets b
    where b.department_id = v_request.department_id
      and b.request_type = v_request.request_type
      and b.is_active = true
    order by b.created_at desc
    limit 1;
  end if;

  if v_budget_id is null then
    update requests
    set budget_check_result = 'EXCEEDS',
        requires_preapproval = true
    where id = v_request.id;

    return query
    select v_request.id, v_request.total_amount, null::uuid, 0::numeric(14,2),
           'EXCEEDS'::budget_check_result, true;
    return;
  end if;

  select fn_budget_available(v_budget_id) into v_available;

  if v_request.total_amount <= coalesce(v_available, 0) then
    update requests
    set budget_check_result = 'WITHIN',
        requires_preapproval = false
    where id = v_request.id;

    return query
    select v_request.id, v_request.total_amount, v_budget_id, coalesce(v_available, 0),
           'WITHIN'::budget_check_result, false;
  else
    update requests
    set budget_check_result = 'EXCEEDS',
        requires_preapproval = true
    where id = v_request.id;

    return query
    select v_request.id, v_request.total_amount, v_budget_id, coalesce(v_available, 0),
           'EXCEEDS'::budget_check_result, true;
  end if;
end;
$$;

-- ======================================
-- Core function: start approval workflow
-- ======================================
create or replace function start_approval_workflow(
  p_entity_type text,
  p_entity_id uuid,
  p_scope workflow_scope,
  p_request_type request_type default null,
  p_payment_type payment_type default null
)
returns uuid
language plpgsql
as $$
declare
  v_workflow_id uuid;
  v_instance_id uuid;
begin
  if p_entity_type not in ('REQUEST', 'LIQUIDATION') then
    raise exception 'Invalid entity type: %', p_entity_type;
  end if;

  select aw.id into v_workflow_id
  from approval_workflows aw
  where aw.scope = p_scope
    and aw.is_active = true
    and (aw.request_type is null or aw.request_type = p_request_type)
    and (aw.payment_type is null or aw.payment_type = p_payment_type)
  order by aw.created_at desc
  limit 1;

  if v_workflow_id is null then
    raise exception 'No active workflow found for scope=% request_type=% payment_type=%',
      p_scope, p_request_type, p_payment_type;
  end if;

  insert into approval_instances(entity_type, entity_id, workflow_id, current_level_no, status)
  values (p_entity_type, p_entity_id, v_workflow_id, 1, 'PENDING')
  returning id into v_instance_id;

  return v_instance_id;
end;
$$;

-- ======================================
-- Core function: submit request
-- ======================================
create or replace function submit_request(p_request_id uuid, p_submitted_by uuid)
returns table (
  request_id uuid,
  final_status request_status,
  approval_instance_id uuid,
  budget_result budget_check_result,
  preapproval_required boolean
)
language plpgsql
as $$
declare
  v_request requests%rowtype;
  v_budget record;
  v_scope workflow_scope;
  v_approval_instance_id uuid;
  v_next_status request_status;
begin
  select * into v_request
  from requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Request not found: %', p_request_id;
  end if;

  if v_request.status not in ('DRAFT', 'RETURNED_FOR_REVISION') then
    raise exception 'Request % cannot be submitted from status %', v_request.request_no, v_request.status;
  end if;

  if v_request.total_amount <= 0 then
    raise exception 'Request total_amount must be > 0';
  end if;

  select * into v_budget
  from run_budget_check(v_request.id);

  if v_budget.requires_preapproval then
    v_scope := 'PRE_APPROVAL';
    v_next_status := 'FOR_PRE_APPROVAL';
  else
    v_scope := 'REQUEST';
    v_next_status := 'FOR_APPROVAL';
  end if;

  update requests
  set status = v_next_status,
      submitted_at = now(),
      remarks = coalesce(remarks, '')
  where id = v_request.id;

  insert into request_status_history(request_id, from_status, to_status, changed_by, remarks)
  values (v_request.id, v_request.status, v_next_status, p_submitted_by, 'Submitted request');

  v_approval_instance_id := start_approval_workflow(
    'REQUEST',
    v_request.id,
    v_scope,
    v_request.request_type,
    v_request.payment_type
  );

  return query
  select
    v_request.id,
    v_next_status,
    v_approval_instance_id,
    v_budget.budget_result,
    v_budget.requires_preapproval;
end;
$$;
