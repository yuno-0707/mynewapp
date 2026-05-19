-- Phase 4: cash advance release + liquidation processing
-- Requires: schema + phase2 + phase3

-- ======================================
-- Function: release_cash_advance
-- Marks approved CA request as released and transitions to FOR_LIQUIDATION
-- Also moves budget committed -> consumed (if matching budget exists)
-- ======================================
create or replace function release_cash_advance(
  p_request_id uuid,
  p_released_by uuid,
  p_remarks text default null
)
returns table (
  request_id uuid,
  request_no text,
  from_status request_status,
  to_status request_status,
  released_at timestamptz,
  budget_id uuid,
  consumed_delta numeric(14,2)
)
language plpgsql
as $$
declare
  v_request requests%rowtype;
  v_from_status request_status;
  v_budget_id uuid;
begin
  select * into v_request
  from requests
  where id = p_request_id
  for update;

  if not found then
    raise exception 'Request not found: %', p_request_id;
  end if;

  if v_request.payment_type <> 'CASH_ADVANCE' then
    raise exception 'Only CASH_ADVANCE requests can be released';
  end if;

  if v_request.status <> 'APPROVED' then
    raise exception 'Request % must be APPROVED before release. Current status: %', v_request.request_no, v_request.status;
  end if;

  v_from_status := v_request.status;

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

  if v_budget_id is not null then
    update budgets
    set committed_amount = greatest(committed_amount - v_request.total_amount, 0),
        consumed_amount = consumed_amount + v_request.total_amount
    where id = v_budget_id;
  end if;

  update requests
  set status = 'FOR_LIQUIDATION',
      released_at = now()
  where id = v_request.id;

  insert into request_status_history(request_id, from_status, to_status, changed_by, remarks)
  values (v_request.id, v_from_status, 'FOR_LIQUIDATION', p_released_by, coalesce(p_remarks, 'Cash advance released'));

  return query
  select
    v_request.id,
    v_request.request_no,
    v_from_status,
    'FOR_LIQUIDATION'::request_status,
    now(),
    v_budget_id,
    v_request.total_amount;
end;
$$;

-- ======================================
-- Function: recalc_liquidation_totals
-- Recomputes liquidation totals from liquidation_items + liquidation_returns
-- ======================================
create or replace function recalc_liquidation_totals(p_liquidation_id uuid)
returns table (
  liquidation_id uuid,
  total_actual_expense numeric(14,2),
  total_returned_amount numeric(14,2),
  total_excess_amount numeric(14,2),
  requires_excess_approval boolean
)
language plpgsql
as $$
declare
  v_liq liquidations%rowtype;
  v_total_actual numeric(14,2);
  v_total_returned numeric(14,2);
  v_total_excess numeric(14,2);
  v_requires_excess boolean;
begin
  select * into v_liq
  from liquidations
  where id = p_liquidation_id
  for update;

  if not found then
    raise exception 'Liquidation not found: %', p_liquidation_id;
  end if;

  select coalesce(sum(li.actual_expense_amount), 0)::numeric(14,2)
  into v_total_actual
  from liquidation_items li
  where li.liquidation_id = v_liq.id;

  select coalesce(sum(lr.amount_returned), 0)::numeric(14,2)
  into v_total_returned
  from liquidation_returns lr
  where lr.liquidation_id = v_liq.id;

  select coalesce(sum(greatest(li.actual_expense_amount - li.approved_advance_amount, 0)), 0)::numeric(14,2)
  into v_total_excess
  from liquidation_items li
  where li.liquidation_id = v_liq.id;

  v_requires_excess := v_total_excess > 0;

  update liquidations
  set total_actual_expense = v_total_actual,
      total_returned_amount = v_total_returned,
      total_excess_amount = v_total_excess,
      requires_excess_approval = v_requires_excess
  where id = v_liq.id;

  return query
  select v_liq.id, v_total_actual, v_total_returned, v_total_excess, v_requires_excess;
end;
$$;

-- ======================================
-- Function: submit_liquidation
-- Submits liquidation and starts proper approval workflow if needed
-- ======================================
create or replace function submit_liquidation(
  p_liquidation_id uuid,
  p_submitted_by uuid,
  p_remarks text default null
)
returns table (
  liquidation_id uuid,
  request_id uuid,
  from_status liquidation_status,
  to_status liquidation_status,
  requires_excess_approval boolean,
  approval_scope workflow_scope,
  approval_instance_id uuid
)
language plpgsql
as $$
declare
  v_liq liquidations%rowtype;
  v_request requests%rowtype;
  v_recalc record;
  v_scope workflow_scope;
  v_instance_id uuid;
  v_to_status liquidation_status;
begin
  select * into v_liq
  from liquidations
  where id = p_liquidation_id
  for update;

  if not found then
    raise exception 'Liquidation not found: %', p_liquidation_id;
  end if;

  if v_liq.status not in ('PENDING', 'REJECTED') then
    raise exception 'Liquidation % cannot be submitted from status %', v_liq.liquidation_no, v_liq.status;
  end if;

  select * into v_request
  from requests
  where id = v_liq.request_id
  for update;

  if not found then
    raise exception 'Linked request not found for liquidation %', v_liq.id;
  end if;

  if v_request.payment_type <> 'CASH_ADVANCE' then
    raise exception 'Only CASH_ADVANCE requests can have liquidation';
  end if;

  select * into v_recalc
  from recalc_liquidation_totals(v_liq.id);

  if v_recalc.total_actual_expense = 0 and v_recalc.total_returned_amount = 0 then
    raise exception 'Liquidation must have actual expense and/or returned amount before submission';
  end if;

  if v_recalc.requires_excess_approval then
    v_scope := 'EXCESS_LIQUIDATION';
  else
    v_scope := 'LIQUIDATION';
  end if;

  v_to_status := 'FOR_APPROVAL';

  update liquidations
  set status = v_to_status,
      submitted_by = p_submitted_by,
      submitted_at = now()
  where id = v_liq.id;

  insert into liquidation_status_history(liquidation_id, from_status, to_status, changed_by, remarks)
  values (v_liq.id, v_liq.status, v_to_status, p_submitted_by, coalesce(p_remarks, 'Liquidation submitted'));

  v_instance_id := start_approval_workflow(
    'LIQUIDATION',
    v_liq.id,
    v_scope,
    v_request.request_type,
    v_request.payment_type
  );

  return query
  select
    v_liq.id,
    v_request.id,
    v_liq.status,
    v_to_status,
    v_recalc.requires_excess_approval,
    v_scope,
    v_instance_id;
end;
$$;

-- ======================================
-- Function: finalize_liquidation_to_request
-- Sync request status after liquidation is approved
-- ======================================
create or replace function finalize_liquidation_to_request(
  p_liquidation_id uuid,
  p_actor_user_id uuid,
  p_remarks text default null
)
returns table (
  request_id uuid,
  from_status request_status,
  to_status request_status,
  outstanding_amount numeric(14,2)
)
language plpgsql
as $$
declare
  v_liq liquidations%rowtype;
  v_req requests%rowtype;
  v_outstanding numeric(14,2);
  v_to_status request_status;
begin
  select * into v_liq
  from liquidations
  where id = p_liquidation_id
  for update;

  if not found then
    raise exception 'Liquidation not found: %', p_liquidation_id;
  end if;

  if v_liq.status <> 'APPROVED' then
    raise exception 'Liquidation % must be APPROVED to finalize request status. Current status: %', v_liq.liquidation_no, v_liq.status;
  end if;

  select * into v_req
  from requests
  where id = v_liq.request_id
  for update;

  if not found then
    raise exception 'Request not found for liquidation: %', v_liq.id;
  end if;

  v_outstanding := greatest(v_req.total_amount - v_liq.total_actual_expense - v_liq.total_returned_amount, 0);

  if v_outstanding = 0 then
    v_to_status := 'LIQUIDATED';
  else
    v_to_status := 'FOR_LIQUIDATION';
  end if;

  update requests
  set status = v_to_status,
      closed_at = case when v_to_status = 'LIQUIDATED' then now() else closed_at end
  where id = v_req.id;

  insert into request_status_history(request_id, from_status, to_status, changed_by, remarks)
  values (v_req.id, v_req.status, v_to_status, p_actor_user_id, coalesce(p_remarks, 'Request synchronized from liquidation status'));

  return query
  select v_req.id, v_req.status, v_to_status, v_outstanding;
end;
$$;
