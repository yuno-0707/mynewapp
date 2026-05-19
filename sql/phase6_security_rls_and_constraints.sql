-- Phase 6: security hardening (RLS policies), integrity constraints, and operational indexes
-- Requires: schema + prior phases

-- ======================================
-- Enable RLS on core tables
-- ======================================
alter table users enable row level security;
alter table requests enable row level security;
alter table request_items enable row level security;
alter table liquidations enable row level security;
alter table liquidation_items enable row level security;
-- Note: typo-safe fallback if table name is approval_instances, use statement below.
do $$
begin
  if exists (
    select 1 from information_schema.tables
    where table_name = 'approval_instances'
  ) then
    execute 'alter table approval_instances enable row level security';
  end if;
exception when undefined_table then
  null;
end $$;
alter table approval_actions enable row level security;
alter table attachments enable row level security;
alter table notifications enable row level security;
alter table audit_logs enable row level security;

-- ======================================
-- Helper auth functions (Supabase-compatible)
-- ======================================
create or replace function fn_current_user_id()
returns uuid
language sql
stable
as $$
  select u.id
  from users u
  where u.auth_user_id = auth.uid()
  limit 1;
$$;

create or replace function fn_user_has_role(p_user_id uuid, p_role_code text)
returns boolean
language sql
stable
as $$
  select exists (
    select 1
    from user_roles ur
    join roles r on r.id = ur.role_id
    where ur.user_id = p_user_id
      and r.code = p_role_code
      and r.is_active = true
  );
$$;

create or replace function fn_is_admin(p_user_id uuid)
returns boolean
language sql
stable
as $$
  select fn_user_has_role(p_user_id, 'ADMIN');
$$;

-- ======================================
-- RLS policies: users
-- ======================================
drop policy if exists users_select_self_or_admin on users;
create policy users_select_self_or_admin on users
for select
using (
  id = fn_current_user_id()
  or fn_is_admin(fn_current_user_id())
);

drop policy if exists users_update_self_or_admin on users;
create policy users_update_self_or_admin on users
for update
using (
  id = fn_current_user_id()
  or fn_is_admin(fn_current_user_id())
)
with check (
  id = fn_current_user_id()
  or fn_is_admin(fn_current_user_id())
);

-- ======================================
-- RLS policies: requests and items
-- ======================================
drop policy if exists requests_select_scoped on requests;
create policy requests_select_scoped on requests
for select
using (
  requestor_id = fn_current_user_id()
  or fn_is_admin(fn_current_user_id())
  or fn_user_has_role(fn_current_user_id(), 'APPROVER')
  or fn_user_has_role(fn_current_user_id(), 'FINANCE_PROCESSOR')
  or fn_user_has_role(fn_current_user_id(), 'FINANCE_REVIEWER')
  or fn_user_has_role(fn_current_user_id(), 'VIEWER')
);

drop policy if exists requests_insert_requestor_or_admin on requests;
create policy requests_insert_requestor_or_admin on requests
for insert
with check (
  requestor_id = fn_current_user_id()
  or fn_is_admin(fn_current_user_id())
);

drop policy if exists requests_update_owner_or_admin on requests;
create policy requests_update_owner_or_admin on requests
for update
using (
  requestor_id = fn_current_user_id()
  or fn_is_admin(fn_current_user_id())
)
with check (
  requestor_id = fn_current_user_id()
  or fn_is_admin(fn_current_user_id())
);

drop policy if exists request_items_select_scoped on request_items;
create policy request_items_select_scoped on request_items
for select
using (
  exists (
    select 1
    from requests r
    where r.id = request_items.request_id
      and (
        r.requestor_id = fn_current_user_id()
        or fn_is_admin(fn_current_user_id())
        or fn_user_has_role(fn_current_user_id(), 'APPROVER')
        or fn_user_has_role(fn_current_user_id(), 'FINANCE_PROCESSOR')
        or fn_user_has_role(fn_current_user_id(), 'FINANCE_REVIEWER')
        or fn_user_has_role(fn_current_user_id(), 'VIEWER')
      )
  )
);

-- ======================================
-- RLS policies: liquidations and items
-- ======================================
drop policy if exists liquidations_select_scoped on liquidations;
create policy liquidations_select_scoped on liquidations
for select
using (
  exists (
    select 1
    from requests r
    where r.id = liquidations.request_id
      and (
        r.requestor_id = fn_current_user_id()
        or fn_is_admin(fn_current_user_id())
        or fn_user_has_role(fn_current_user_id(), 'APPROVER')
        or fn_user_has_role(fn_current_user_id(), 'FINANCE_PROCESSOR')
        or fn_user_has_role(fn_current_user_id(), 'FINANCE_REVIEWER')
        or fn_user_has_role(fn_current_user_id(), 'VIEWER')
      )
  )
);

drop policy if exists liquidations_insert_owner_or_finance_or_admin on liquidations;
create policy liquidations_insert_owner_or_finance_or_admin on liquidations
for insert
with check (
  exists (
    select 1
    from requests r
    where r.id = liquidations.request_id
      and (
        r.requestor_id = fn_current_user_id()
        or fn_user_has_role(fn_current_user_id(), 'FINANCE_PROCESSOR')
        or fn_is_admin(fn_current_user_id())
      )
  )
);

-- ======================================
-- RLS policies: attachments
-- ======================================
drop policy if exists attachments_select_scoped on attachments;
create policy attachments_select_scoped on attachments
for select
using (
  fn_is_admin(fn_current_user_id())
  or fn_user_has_role(fn_current_user_id(), 'APPROVER')
  or fn_user_has_role(fn_current_user_id(), 'FINANCE_PROCESSOR')
  or fn_user_has_role(fn_current_user_id(), 'FINANCE_REVIEWER')
  or exists (
    select 1
    from requests r
    where attachments.entity_type = 'REQUEST'
      and attachments.entity_id = r.id
      and r.requestor_id = fn_current_user_id()
  )
  or exists (
    select 1
    from liquidations l
    join requests r on r.id = l.request_id
    where attachments.entity_type = 'LIQUIDATION'
      and attachments.entity_id = l.id
      and r.requestor_id = fn_current_user_id()
  )
);

-- ======================================
-- RLS policies: notifications
-- ======================================
drop policy if exists notifications_select_self_or_admin on notifications;
create policy notifications_select_self_or_admin on notifications
for select
using (
  user_id = fn_current_user_id()
  or fn_is_admin(fn_current_user_id())
);

-- ======================================
-- Additional integrity constraints
-- ======================================
alter table requests
  add constraint chk_requests_project_or_department_required
  check (
    (request_type = 'PROJECT' and project_id is not null)
    or (request_type in ('OPEX', 'CAPEX') and department_id is not null)
  );

alter table approval_levels
  add constraint chk_approval_levels_role_or_user
  check (
    approver_role_id is not null
    or approver_user_id is not null
  );

alter table liquidation_items
  add constraint chk_liquidation_items_amounts_nonnegative
  check (
    approved_advance_amount >= 0
    and actual_expense_amount >= 0
  );

-- ======================================
-- Operational indexes for dashboards/queues
-- ======================================
create index if not exists idx_requests_type_payment_status
  on requests(request_type, payment_type, status);

create index if not exists idx_requests_due_status
  on requests(liquidation_due_date, status)
  where payment_type = 'CASH_ADVANCE';

create index if not exists idx_liquidations_request_status
  on liquidations(request_id, status);

create index if not exists idx_attachments_entity
  on attachments(entity_type, entity_id);

create index if not exists idx_notifications_pending_email
  on notifications(channel, status, scheduled_for)
  where channel = 'EMAIL' and status = 'PENDING';

create index if not exists idx_approval_instances_entity_status
  on approval_instances(entity_type, entity_id, status);
