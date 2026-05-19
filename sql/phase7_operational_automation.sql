-- Phase 7: operational automation, dashboard helpers, and audit utilities
-- Requires: schema + phase2..phase6

-- ======================================
-- Overdue updater for cash advances / liquidations
-- ======================================
create or replace function mark_overdue_cash_advances(p_actor_user_id uuid default null)
returns integer
language plpgsql
as $$
declare
  v_updated_count integer;
begin
  with overdue_requests as (
    select r.id
    from requests r
    left join liquidations l on l.request_id = r.id
    where r.payment_type = 'CASH_ADVANCE'
      and r.liquidation_due_date < current_date
      and greatest(r.total_amount - coalesce(l.total_actual_expense, 0) - coalesce(l.total_returned_amount, 0), 0) > 0
      and r.status in ('FOR_LIQUIDATION', 'LIQUIDATED')
  ), req_updates as (
    update requests r
    set status = 'FOR_LIQUIDATION'
    from overdue_requests o
    where r.id = o.id
    returning r.id
  )
  select count(*) into v_updated_count from req_updates;

  insert into liquidation_status_history (liquidation_id, from_status, to_status, changed_by, remarks)
  select l.id,
         l.status,
         'OVERDUE'::liquidation_status,
         p_actor_user_id,
         'Auto-marked overdue by scheduler'
  from liquidations l
  join requests r on r.id = l.request_id
  where r.payment_type = 'CASH_ADVANCE'
    and r.liquidation_due_date < current_date
    and greatest(r.total_amount - coalesce(l.total_actual_expense, 0) - coalesce(l.total_returned_amount, 0), 0) > 0
    and l.status <> 'OVERDUE';

  update liquidations l
  set status = 'OVERDUE'
  from requests r
  where r.id = l.request_id
    and r.payment_type = 'CASH_ADVANCE'
    and r.liquidation_due_date < current_date
    and greatest(r.total_amount - coalesce(l.total_actual_expense, 0) - coalesce(l.total_returned_amount, 0), 0) > 0
    and l.status <> 'OVERDUE';

  return coalesce(v_updated_count, 0);
end;
$$;

-- ======================================
-- Dashboard KPI view
-- ======================================
create or replace view v_dashboard_kpis as
select
  count(*)::bigint as total_requests,
  count(*) filter (where status in ('SUBMITTED', 'FOR_PRE_APPROVAL', 'FOR_APPROVAL'))::bigint as pending_requests,
  count(*) filter (where status = 'APPROVED')::bigint as approved_requests,
  count(*) filter (where status = 'REJECTED')::bigint as rejected_requests,
  count(*) filter (where payment_type = 'CASH_ADVANCE')::bigint as total_cash_advances,
  count(*) filter (
    where payment_type = 'CASH_ADVANCE'
      and exists (
        select 1
        from v_report_aging_outstanding_unliquidated a
        where a.cash_advance_reference_no = requests.request_no
          and a.outstanding_amount > 0
      )
  )::bigint as total_unliquidated_cash_advances,
  count(*) filter (
    where payment_type = 'CASH_ADVANCE'
      and exists (
        select 1
        from v_report_aging_outstanding_unliquidated a
        where a.cash_advance_reference_no = requests.request_no
          and a.outstanding_amount > 0
          and a.due_date < current_date
      )
  )::bigint as total_overdue_cash_advances,
  coalesce(sum(
    case
      when payment_type = 'CASH_ADVANCE' then (
        select coalesce(l.total_returned_amount, 0)
        from liquidations l
        where l.request_id = requests.id
      )
      else 0
    end
  ), 0)::numeric(14,2) as total_returned_funds,
  count(*) filter (where budget_check_result = 'EXCEEDS')::bigint as requests_exceeding_budget,
  count(*) filter (where status = 'FOR_APPROVAL')::bigint as requests_pending_approval,
  count(*) filter (
    where payment_type = 'CASH_ADVANCE'
      and liquidation_due_date between current_date and (current_date + 2)
      and exists (
        select 1
        from v_report_aging_outstanding_unliquidated a
        where a.cash_advance_reference_no = requests.request_no
          and a.outstanding_amount > 0
      )
  )::bigint as liquidation_due_soon
from requests;

-- ======================================
-- Notification queue helper: overdue alerts
-- ======================================
create or replace function queue_overdue_alerts(
  p_scheduled_for timestamptz default now(),
  p_base_url text default 'https://app.example.com/liquidation'
)
returns integer
language plpgsql
as $$
declare
  v_inserted_count integer;
begin
  with candidates as (
    select
      r.id as request_id,
      r.request_no,
      r.requestor_id,
      u.display_name as requestor_name,
      r.liquidation_due_date,
      greatest(r.total_amount - coalesce(l.total_actual_expense, 0) - coalesce(l.total_returned_amount, 0), 0)::numeric(14,2) as outstanding_amount
    from requests r
    join users u on u.id = r.requestor_id
    left join liquidations l on l.request_id = r.id
    where r.payment_type = 'CASH_ADVANCE'
      and r.liquidation_due_date < current_date
      and greatest(r.total_amount - coalesce(l.total_actual_expense, 0) - coalesce(l.total_returned_amount, 0), 0) > 0
  ), inserted as (
    insert into notifications (
      user_id,
      channel,
      template_code,
      subject,
      payload,
      status,
      scheduled_for
    )
    select
      c.requestor_id,
      'EMAIL'::notification_channel,
      'OVERDUE_ALERT',
      'Overdue Cash Advance Liquidation Alert',
      jsonb_build_object(
        'requestor_name', c.requestor_name,
        'cash_advance_reference_no', c.request_no,
        'due_date', c.liquidation_due_date,
        'outstanding_amount', c.outstanding_amount,
        'required_action', 'Your cash advance is overdue. Submit liquidation immediately.',
        'submit_liquidation_link', p_base_url || '?request_id=' || c.request_id::text
      ),
      'PENDING'::notification_status,
      p_scheduled_for
    from candidates c
    returning id
  )
  select count(*) into v_inserted_count from inserted;

  return coalesce(v_inserted_count, 0);
end;
$$;

-- ======================================
-- Scheduler entrypoint (single function for cron)
-- ======================================
create or replace function run_daily_finance_jobs(
  p_actor_user_id uuid default null,
  p_scheduled_for timestamptz default now(),
  p_days_before_overdue integer default 2,
  p_base_url text default 'https://app.example.com/liquidation'
)
returns jsonb
language plpgsql
as $$
declare
  v_overdue_updated integer;
  v_daily_digest integer;
  v_pre_overdue integer;
  v_overdue_alerts integer;
begin
  v_overdue_updated := mark_overdue_cash_advances(p_actor_user_id);
  v_daily_digest := queue_daily_unliquidated_digest(p_scheduled_for);
  v_pre_overdue := queue_pre_overdue_reminders(p_scheduled_for, p_days_before_overdue, p_base_url);
  v_overdue_alerts := queue_overdue_alerts(p_scheduled_for, p_base_url);

  return jsonb_build_object(
    'overdue_requests_marked', v_overdue_updated,
    'daily_digest_queued', v_daily_digest,
    'pre_overdue_reminders_queued', v_pre_overdue,
    'overdue_alerts_queued', v_overdue_alerts,
    'run_at', now()
  );
end;
$$;
