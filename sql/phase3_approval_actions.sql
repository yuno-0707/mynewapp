-- Phase 3: approval action engine with level progression and entity finalization
-- Requires: sql/schema.sql and sql/phase2_seed_and_functions.sql already applied

-- ======================================
-- Function: apply_approval_action
-- Handles APPROVE / REJECT / RETURN for request or liquidation approval instances
-- ======================================
create or replace function apply_approval_action(
  p_approval_instance_id uuid,
  p_approver_id uuid,
  p_action approval_action_type,
  p_remarks text default null
)
returns table (
  approval_instance_id uuid,
  entity_type text,
  entity_id uuid,
  action_taken approval_action_type,
  from_level integer,
  to_level integer,
  approval_instance_status text,
  request_status_result request_status,
  liquidation_status_result liquidation_status
)
language plpgsql
as $$
declare
  v_instance approval_instances%rowtype;
  v_workflow approval_workflows%rowtype;
  v_max_level integer;
  v_from_level integer;
  v_to_level integer;
  v_request requests%rowtype;
  v_liq liquidations%rowtype;
  v_req_to_status request_status;
  v_liq_to_status liquidation_status;
  v_next_instance_status text;
begin
  select * into v_instance
  from approval_instances
  where id = p_approval_instance_id
  for update;

  if not found then
    raise exception 'Approval instance not found: %', p_approval_instance_id;
  end if;

  if coalesce(v_instance.status, 'PENDING') in ('APPROVED', 'REJECTED', 'RETURNED') then
    raise exception 'Approval instance % is already finalized with status %', v_instance.id, v_instance.status;
  end if;

  select * into v_workflow
  from approval_workflows
  where id = v_instance.workflow_id;

  select max(level_no) into v_max_level
  from approval_levels
  where workflow_id = v_instance.workflow_id
    and is_active = true;

  if v_max_level is null then
    raise exception 'No active approval levels found for workflow %', v_instance.workflow_id;
  end if;

  v_from_level := v_instance.current_level_no;
  v_to_level := v_from_level;
  v_req_to_status := null;
  v_liq_to_status := null;

  insert into approval_actions(
    approval_instance_id,
    level_no,
    approver_id,
    action,
    remarks,
    acted_at
  )
  values (
    v_instance.id,
    v_from_level,
    p_approver_id,
    p_action,
    p_remarks,
    now()
  );

  if p_action = 'APPROVE' then
    if v_from_level < v_max_level then
      v_to_level := v_from_level + 1;
      v_next_instance_status := 'PENDING';

      update approval_instances
      set current_level_no = v_to_level,
          status = v_next_instance_status
      where id = v_instance.id;
    else
      -- Final approval
      v_to_level := v_from_level;
      v_next_instance_status := 'APPROVED';

      update approval_instances
      set status = v_next_instance_status,
          completed_at = now()
      where id = v_instance.id;

      if v_instance.entity_type = 'REQUEST' then
        select * into v_request
        from requests
        where id = v_instance.entity_id
        for update;

        if not found then
          raise exception 'Request not found for approval entity_id=%', v_instance.entity_id;
        end if;

        if v_workflow.scope = 'PRE_APPROVAL' then
          v_req_to_status := 'PRE_APPROVED';
        else
          v_req_to_status := 'APPROVED';
        end if;

        update requests
        set status = v_req_to_status,
            approved_at = case when v_req_to_status = 'APPROVED' then now() else approved_at end
        where id = v_request.id;

        insert into request_status_history(request_id, from_status, to_status, changed_by, remarks)
        values (v_request.id, v_request.status, v_req_to_status, p_approver_id, coalesce(p_remarks, 'Final approval'));

      elsif v_instance.entity_type = 'LIQUIDATION' then
        select * into v_liq
        from liquidations
        where id = v_instance.entity_id
        for update;

        if not found then
          raise exception 'Liquidation not found for approval entity_id=%', v_instance.entity_id;
        end if;

        v_liq_to_status := 'APPROVED';

        update liquidations
        set status = v_liq_to_status,
            approved_at = now()
        where id = v_liq.id;

        insert into liquidation_status_history(liquidation_id, from_status, to_status, changed_by, remarks)
        values (v_liq.id, v_liq.status, v_liq_to_status, p_approver_id, coalesce(p_remarks, 'Final approval'));
      else
        raise exception 'Unsupported entity_type: %', v_instance.entity_type;
      end if;
    end if;

  elsif p_action = 'REJECT' then
    v_to_level := v_from_level;
    v_next_instance_status := 'REJECTED';

    update approval_instances
    set status = v_next_instance_status,
        completed_at = now()
    where id = v_instance.id;

    if v_instance.entity_type = 'REQUEST' then
      select * into v_request
      from requests
      where id = v_instance.entity_id
      for update;

      if not found then
        raise exception 'Request not found for approval entity_id=%', v_instance.entity_id;
      end if;

      v_req_to_status := 'REJECTED';

      update requests
      set status = v_req_to_status
      where id = v_request.id;

      insert into request_status_history(request_id, from_status, to_status, changed_by, remarks)
      values (v_request.id, v_request.status, v_req_to_status, p_approver_id, coalesce(p_remarks, 'Rejected'));

    elsif v_instance.entity_type = 'LIQUIDATION' then
      select * into v_liq
      from liquidations
      where id = v_instance.entity_id
      for update;

      if not found then
        raise exception 'Liquidation not found for approval entity_id=%', v_instance.entity_id;
      end if;

      v_liq_to_status := 'REJECTED';

      update liquidations
      set status = v_liq_to_status,
          rejected_at = now()
      where id = v_liq.id;

      insert into liquidation_status_history(liquidation_id, from_status, to_status, changed_by, remarks)
      values (v_liq.id, v_liq.status, v_liq_to_status, p_approver_id, coalesce(p_remarks, 'Rejected'));
    else
      raise exception 'Unsupported entity_type: %', v_instance.entity_type;
    end if;

  elsif p_action = 'RETURN' then
    v_to_level := v_from_level;
    v_next_instance_status := 'RETURNED';

    update approval_instances
    set status = v_next_instance_status,
        completed_at = now()
    where id = v_instance.id;

    if v_instance.entity_type = 'REQUEST' then
      select * into v_request
      from requests
      where id = v_instance.entity_id
      for update;

      if not found then
        raise exception 'Request not found for approval entity_id=%', v_instance.entity_id;
      end if;

      v_req_to_status := 'RETURNED_FOR_REVISION';

      update requests
      set status = v_req_to_status
      where id = v_request.id;

      insert into request_status_history(request_id, from_status, to_status, changed_by, remarks)
      values (v_request.id, v_request.status, v_req_to_status, p_approver_id, coalesce(p_remarks, 'Returned for revision'));

    elsif v_instance.entity_type = 'LIQUIDATION' then
      select * into v_liq
      from liquidations
      where id = v_instance.entity_id
      for update;

      if not found then
        raise exception 'Liquidation not found for approval entity_id=%', v_instance.entity_id;
      end if;

      v_liq_to_status := 'PENDING';

      update liquidations
      set status = v_liq_to_status
      where id = v_liq.id;

      insert into liquidation_status_history(liquidation_id, from_status, to_status, changed_by, remarks)
      values (v_liq.id, v_liq.status, v_liq_to_status, p_approver_id, coalesce(p_remarks, 'Returned for revision'));
    else
      raise exception 'Unsupported entity_type: %', v_instance.entity_type;
    end if;

  else
    raise exception 'Unsupported action: %', p_action;
  end if;

  return query
  select
    v_instance.id,
    v_instance.entity_type,
    v_instance.entity_id,
    p_action,
    v_from_level,
    v_to_level,
    v_next_instance_status,
    v_req_to_status,
    v_liq_to_status;
end;
$$;
