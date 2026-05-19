-- Requisition and Cash Advance Management System
-- PostgreSQL / Supabase-ready schema

-- =========================
-- Extensions
-- =========================
create extension if not exists pgcrypto;

-- =========================
-- Enums
-- =========================
create type request_type as enum ('PROJECT', 'OPEX', 'CAPEX');
create type payment_type as enum ('CASH_ADVANCE', 'DIRECT');
create type request_status as enum (
  'DRAFT',
  'SUBMITTED',
  'FOR_PRE_APPROVAL',
  'PRE_APPROVED',
  'FOR_APPROVAL',
  'APPROVED',
  'REJECTED',
  'RETURNED_FOR_REVISION',
  'RELEASED',
  'FOR_LIQUIDATION',
  'LIQUIDATED',
  'CLOSED',
  'ARCHIVED'
);
create type liquidation_status as enum (
  'PENDING',
  'SUBMITTED',
  'FOR_APPROVAL',
  'APPROVED',
  'REJECTED',
  'PARTIALLY_LIQUIDATED',
  'FULLY_LIQUIDATED',
  'OVERDUE'
);
create type approval_action_type as enum ('APPROVE', 'REJECT', 'RETURN');
create type workflow_scope as enum ('REQUEST', 'LIQUIDATION', 'PRE_APPROVAL', 'EXCESS_LIQUIDATION');
create type budget_check_result as enum ('NA', 'WITHIN', 'EXCEEDS');
create type request_item_category as enum ('MANPOWER', 'OTHER_REQUEST');
create type attachment_entity_type as enum ('REQUEST', 'LIQUIDATION', 'USER', 'MASTERLIST');
create type notification_channel as enum ('EMAIL', 'IN_APP');
create type notification_status as enum ('PENDING', 'SENT', 'FAILED', 'CANCELLED');

-- =========================
-- Common timestamp trigger
-- =========================
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

-- =========================
-- Security / Identity
-- =========================
create table roles (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  description text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table permissions (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  description text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table role_permissions (
  role_id uuid not null references roles(id) on delete cascade,
  permission_id uuid not null references permissions(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (role_id, permission_id)
);

create table users (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid unique,
  email text unique not null,
  first_name text not null,
  last_name text not null,
  display_name text generated always as (first_name || ' ' || last_name) stored,
  is_active boolean not null default true,
  password_reset_required boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table user_roles (
  user_id uuid not null references users(id) on delete cascade,
  role_id uuid not null references roles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, role_id)
);

-- =========================
-- Masterlists (archivable)
-- =========================
create table companies (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  is_active boolean not null default true,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table business_units (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  is_active boolean not null default true,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table clients (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  business_unit_id uuid references business_units(id),
  is_active boolean not null default true,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table departments (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  is_active boolean not null default true,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table project_categories (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  is_active boolean not null default true,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table project_types (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  is_active boolean not null default true,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table brands (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  is_active boolean not null default true,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table project_statuses (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  is_active boolean not null default true,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table budget_categories (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  is_active boolean not null default true,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table projects (
  id uuid primary key default gen_random_uuid(),
  code text unique not null,
  name text not null,
  company_id uuid not null references companies(id),
  client_id uuid not null references clients(id),
  business_unit_id uuid not null references business_units(id),
  project_category_id uuid references project_categories(id),
  project_type_id uuid references project_types(id),
  brand_id uuid references brands(id),
  project_status_id uuid references project_statuses(id),
  billing_personnel_id uuid references users(id),
  is_active boolean not null default true,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =========================
-- CE Upload / Import
-- =========================
create table ce_headers (
  id uuid primary key default gen_random_uuid(),
  ce_code text unique not null,
  project_id uuid not null references projects(id),
  total_ce_amount numeric(14,2),
  uploaded_by uuid references users(id),
  uploaded_at timestamptz not null default now(),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table ce_items (
  id uuid primary key default gen_random_uuid(),
  ce_header_id uuid not null references ce_headers(id) on delete cascade,
  line_no integer not null,
  item_code text,
  description text not null,
  budget_category_id uuid references budget_categories(id),
  planned_amount numeric(14,2) not null check (planned_amount >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (ce_header_id, line_no)
);

-- =========================
-- Budgeting
-- =========================
create table budgets (
  id uuid primary key default gen_random_uuid(),
  fiscal_year integer not null,
  request_type request_type not null,
  department_id uuid references departments(id),
  project_id uuid references projects(id),
  budget_category_id uuid references budget_categories(id),
  allocated_amount numeric(14,2) not null check (allocated_amount >= 0),
  consumed_amount numeric(14,2) not null default 0 check (consumed_amount >= 0),
  committed_amount numeric(14,2) not null default 0 check (committed_amount >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =========================
-- Requests
-- =========================
create table requests (
  id uuid primary key default gen_random_uuid(),
  request_no text unique not null,
  request_type request_type not null,
  payment_type payment_type not null,
  requestor_id uuid not null references users(id),
  company_id uuid references companies(id),
  client_id uuid references clients(id),
  business_unit_id uuid references business_units(id),
  project_id uuid references projects(id),
  ce_header_id uuid references ce_headers(id),
  department_id uuid references departments(id),
  billing_personnel_id uuid references users(id),
  status request_status not null default 'DRAFT',
  budget_check_result budget_check_result not null default 'NA',
  requires_preapproval boolean not null default false,
  liquidation_due_date date,
  released_at timestamptz,
  total_amount numeric(14,2) not null default 0 check (total_amount >= 0),
  remarks text,
  submitted_at timestamptz,
  approved_at timestamptz,
  closed_at timestamptz,
  is_archived boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (
    (payment_type = 'CASH_ADVANCE' and liquidation_due_date is not null)
    or payment_type = 'DIRECT'
  )
);

create table request_items (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references requests(id) on delete cascade,
  line_no integer not null,
  ce_item_id uuid references ce_items(id),
  budget_category_id uuid references budget_categories(id),
  category request_item_category not null,
  description text not null,
  quantity numeric(14,2) not null default 1 check (quantity > 0),
  unit_cost numeric(14,2) not null default 0 check (unit_cost >= 0),
  amount numeric(14,2) not null check (amount >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (request_id, line_no)
);

create table attachments (
  id uuid primary key default gen_random_uuid(),
  entity_type attachment_entity_type not null,
  entity_id uuid not null,
  attachment_type text not null,
  file_name text not null,
  storage_path text not null,
  mime_type text,
  file_size_bytes bigint,
  uploaded_by uuid references users(id),
  created_at timestamptz not null default now()
);

-- =========================
-- Approval workflow
-- =========================
create table approval_workflows (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  scope workflow_scope not null,
  request_type request_type,
  payment_type payment_type,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table approval_levels (
  id uuid primary key default gen_random_uuid(),
  workflow_id uuid not null references approval_workflows(id) on delete cascade,
  level_no integer not null,
  approver_role_id uuid references roles(id),
  approver_user_id uuid references users(id),
  min_amount numeric(14,2),
  max_amount numeric(14,2),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (workflow_id, level_no)
);

create table approval_instances (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type in ('REQUEST', 'LIQUIDATION')),
  entity_id uuid not null,
  workflow_id uuid not null references approval_workflows(id),
  current_level_no integer not null default 1,
  status text not null default 'PENDING',
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table approval_actions (
  id uuid primary key default gen_random_uuid(),
  approval_instance_id uuid not null references approval_instances(id) on delete cascade,
  level_no integer not null,
  approver_id uuid not null references users(id),
  action approval_action_type not null,
  remarks text,
  acted_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);

-- =========================
-- Liquidation
-- =========================
create table liquidations (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null unique references requests(id),
  liquidation_no text unique not null,
  submitted_by uuid references users(id),
  status liquidation_status not null default 'PENDING',
  total_actual_expense numeric(14,2) not null default 0,
  total_returned_amount numeric(14,2) not null default 0,
  total_excess_amount numeric(14,2) not null default 0,
  requires_excess_approval boolean not null default false,
  submitted_at timestamptz,
  approved_at timestamptz,
  rejected_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table liquidation_items (
  id uuid primary key default gen_random_uuid(),
  liquidation_id uuid not null references liquidations(id) on delete cascade,
  request_item_id uuid not null references request_items(id),
  line_no integer not null,
  approved_advance_amount numeric(14,2) not null default 0,
  actual_expense_amount numeric(14,2) not null default 0,
  variance_amount numeric(14,2) not null default 0,
  is_excess boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (liquidation_id, line_no)
);

create table liquidation_returns (
  id uuid primary key default gen_random_uuid(),
  liquidation_id uuid not null references liquidations(id) on delete cascade,
  amount_returned numeric(14,2) not null check (amount_returned > 0),
  date_returned date not null,
  reference_no text not null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =========================
-- Logs and Notifications
-- =========================
create table request_status_history (
  id uuid primary key default gen_random_uuid(),
  request_id uuid not null references requests(id) on delete cascade,
  from_status request_status,
  to_status request_status not null,
  changed_by uuid references users(id),
  remarks text,
  changed_at timestamptz not null default now()
);

create table liquidation_status_history (
  id uuid primary key default gen_random_uuid(),
  liquidation_id uuid not null references liquidations(id) on delete cascade,
  from_status liquidation_status,
  to_status liquidation_status not null,
  changed_by uuid references users(id),
  remarks text,
  changed_at timestamptz not null default now()
);

create table audit_logs (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid references users(id),
  action text not null,
  module text not null,
  entity_type text,
  entity_id uuid,
  metadata jsonb,
  created_at timestamptz not null default now()
);

create table notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references users(id),
  channel notification_channel not null,
  template_code text not null,
  subject text,
  payload jsonb not null,
  status notification_status not null default 'PENDING',
  scheduled_for timestamptz,
  sent_at timestamptz,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- =========================
-- Indexes
-- =========================
create index idx_requests_status on requests(status);
create index idx_requests_requestor on requests(requestor_id);
create index idx_requests_due_date on requests(liquidation_due_date);
create index idx_request_items_request on request_items(request_id);
create index idx_approvals_entity on approval_instances(entity_type, entity_id);
create index idx_approval_actions_instance on approval_actions(approval_instance_id);
create index idx_liquidation_status on liquidations(status);
create index idx_notifications_status_schedule on notifications(status, scheduled_for);

-- =========================
-- Updated-at triggers
-- =========================
create trigger trg_roles_updated before update on roles for each row execute function set_updated_at();
create trigger trg_permissions_updated before update on permissions for each row execute function set_updated_at();
create trigger trg_users_updated before update on users for each row execute function set_updated_at();
create trigger trg_companies_updated before update on companies for each row execute function set_updated_at();
create trigger trg_business_units_updated before update on business_units for each row execute function set_updated_at();
create trigger trg_clients_updated before update on clients for each row execute function set_updated_at();
create trigger trg_departments_updated before update on departments for each row execute function set_updated_at();
create trigger trg_project_categories_updated before update on project_categories for each row execute function set_updated_at();
create trigger trg_project_types_updated before update on project_types for each row execute function set_updated_at();
create trigger trg_brands_updated before update on brands for each row execute function set_updated_at();
create trigger trg_project_statuses_updated before update on project_statuses for each row execute function set_updated_at();
create trigger trg_budget_categories_updated before update on budget_categories for each row execute function set_updated_at();
create trigger trg_projects_updated before update on projects for each row execute function set_updated_at();
create trigger trg_ce_headers_updated before update on ce_headers for each row execute function set_updated_at();
create trigger trg_ce_items_updated before update on ce_items for each row execute function set_updated_at();
create trigger trg_budgets_updated before update on budgets for each row execute function set_updated_at();
create trigger trg_requests_updated before update on requests for each row execute function set_updated_at();
create trigger trg_request_items_updated before update on request_items for each row execute function set_updated_at();
create trigger trg_approval_workflows_updated before update on approval_workflows for each row execute function set_updated_at();
create trigger trg_approval_levels_updated before update on approval_levels for each row execute function set_updated_at();
create trigger trg_approval_instances_updated before update on approval_instances for each row execute function set_updated_at();
create trigger trg_liquidations_updated before update on liquidations for each row execute function set_updated_at();
create trigger trg_liquidation_items_updated before update on liquidation_items for each row execute function set_updated_at();
create trigger trg_liquidation_returns_updated before update on liquidation_returns for each row execute function set_updated_at();
create trigger trg_notifications_updated before update on notifications for each row execute function set_updated_at();

-- =========================
-- Helpful reporting views
-- =========================
create or replace view v_cash_advance_balances as
select
  r.id as request_id,
  r.request_no,
  r.requestor_id,
  r.project_id,
  r.department_id,
  r.liquidation_due_date,
  r.total_amount as cash_advance_amount,
  coalesce(l.total_actual_expense, 0) as liquidated_amount,
  coalesce(l.total_returned_amount, 0) as returned_amount,
  greatest(r.total_amount - coalesce(l.total_actual_expense, 0) - coalesce(l.total_returned_amount, 0), 0) as outstanding_amount,
  case
    when r.liquidation_due_date is null then null
    else (current_date - r.liquidation_due_date)
  end as days_outstanding
from requests r
left join liquidations l on l.request_id = r.id
where r.payment_type = 'CASH_ADVANCE';

create or replace view v_cash_advance_aging as
select
  b.*,
  case
    when b.outstanding_amount <= 0 then 'CURRENT'
    when b.days_outstanding between 1 and 30 then '1-30 DAYS'
    when b.days_outstanding between 31 and 60 then '31-60 DAYS'
    when b.days_outstanding between 61 and 90 then '61-90 DAYS'
    when b.days_outstanding > 90 then 'OVER 90 DAYS'
    else 'NOT YET DUE'
  end as aging_bucket
from v_cash_advance_balances b;
