-- Phase 5: reporting views + export helpers + notification queue generators
-- Requires: schema + phase2 + phase3 + phase4

-- ======================================
-- Report View: aging of outstanding unliquidated cash advances
-- ======================================
create or replace view v_report_aging_outstanding_unliquidated as
select
  r.request_no as cash_advance_reference_no,
  u.display_name as requestor_name,
  coalesce(p.name, d.name) as project_or_department,
  r.total_amount as cash_advance_amount,
  coalesce(l.total_actual_expense, 0)::numeric(14,2) as liquidated_amount,
  coalesce(l.total_returned_amount, 0)::numeric(14,2) as returned_amount,
  greatest(r.total_amount - coalesce(l.total_actual_expense, 0) - coalesce(l.total_returned_amount, 0), 0)::numeric(14,2) as outstanding_amount,
  r.liquidation_due_date as due_date,
  case
    when r.liquidation_due_date is null then null
    else (current_date - r.liquidation_due_date)
  end as days_outstanding,
  case
    when greatest(r.total_amount - coalesce(l.total_actual_expense, 0) - coalesce(l.total_returned_amount, 0), 0) <= 0 then 'CURRENT'
    when (current_date - r.liquidation_due_date) between 1 and 30 then '1-30 DAYS'
    when (current_date - r.liquidation_due_date) between 31 and 60 then '31-60 DAYS'
    when (current_date - r.liquidation_due_date) between 61 and 90 then '61-90 DAYS'
    when (current_date - r.liquidation_due_date) > 90 then 'OVER 90 DAYS'
    else 'NOT YET DUE'
  end as aging_bucket
from requests r
join users u on u.id = r.requestor_id
left join projects p on p.id = r.project_id
left join departments d on d.id = r.department_id
left join liquidations l on l.request_id = r.id
where r.payment_type = 'CASH_ADVANCE';

-- ======================================
-- Report View: total requests made per project
-- ======================================
create or replace view v_report_total_requests_per_project as
select
  p.id as project_id,
  p.code as project_code,
  p.name as project_name,
  ch.ce_code,
  coalesce(sum(r.total_amount), 0)::numeric(14,2) as total_requests,
  coalesce(sum(case when r.payment_type = 'CASH_ADVANCE' then r.total_amount else 0 end), 0)::numeric(14,2) as total_cash_advances,
  coalesce(sum(case when r.payment_type = 'DIRECT' then r.total_amount else 0 end), 0)::numeric(14,2) as total_direct_requests,
  coalesce(sum(coalesce(l.total_actual_expense, 0)), 0)::numeric(14,2) as liquidated_amount,
  coalesce(sum(coalesce(l.total_returned_amount, 0)), 0)::numeric(14,2) as returned_funds,
  (coalesce(sum(r.total_amount), 0) - coalesce(sum(coalesce(l.total_returned_amount, 0)), 0))::numeric(14,2) as net_request_amount
from projects p
left join requests r on r.project_id = p.id
left join ce_headers ch on ch.id = r.ce_header_id
left join liquidations l on l.request_id = r.id
group by p.id, p.code, p.name, ch.ce_code;

-- ======================================
-- Report View: summary of unliquidated CAs per requestor
-- ======================================
create or replace view v_report_unliquidated_summary_per_requestor as
select
  u.id as requestor_id,
  u.display_name as requestor_name,
  coalesce(sum(r.total_amount), 0)::numeric(14,2) as total_cash_advance,
  coalesce(sum(coalesce(l.total_actual_expense, 0)), 0)::numeric(14,2) as liquidated_amount,
  coalesce(sum(coalesce(l.total_returned_amount, 0)), 0)::numeric(14,2) as returned_amount,
  coalesce(sum(greatest(r.total_amount - coalesce(l.total_actual_expense, 0) - coalesce(l.total_returned_amount, 0), 0)), 0)::numeric(14,2) as unliquidated_balance,
  coalesce(sum(case when greatest(r.total_amount - coalesce(l.total_actual_expense, 0) - coalesce(l.total_returned_amount, 0), 0) > 0 then 1 else 0 end), 0)::int as number_of_outstanding_requests,
  coalesce(sum(case when greatest(r.total_amount - coalesce(l.total_actual_expense, 0) - coalesce(l.total_returned_amount, 0), 0) > 0 and r.liquidation_due_date < current_date then 1 else 0 end), 0)::int as number_of_overdue_requests
from users u
left join requests r on r.requestor_id = u.id and r.payment_type = 'CASH_ADVANCE'
left join liquidations l on l.request_id = r.id
group by u.id, u.display_name;

-- ======================================
-- Export helper: function wrapper for aging report
-- (allows filtered extraction by date range)
-- ======================================
create or replace function fn_report_aging_outstanding(
  p_due_date_from date default null,
  p_due_date_to date default null,
  p_requestor_id uuid default null
)
returns table (
  cash_advance_reference_no text,
  requestor_name text,
  project_or_department text,
  cash_advance_amount numeric(14,2),
  liquidated_amount numeric(14,2),
  returned_amount numeric(14,2),
  outstanding_amount numeric(14,2),
  due_date date,
  days_outstanding integer,
  aging_bucket text
)
language sql
stable
as $$
  select
    v.cash_advance_reference_no,
    v.requestor_name,
    v.project_or_department,
    v.cash_advance_amount,
    v.liquidated_amount,
    v.returned_amount,
    v.outstanding_amount,
    v.due_date,
    v.days_outstanding,
    v.aging_bucket
  from v_report_aging_outstanding_unliquidated v
  join requests r on r.request_no = v.cash_advance_reference_no
  where (p_due_date_from is null or v.due_date >= p_due_date_from)
    and (p_due_date_to is null or v.due_date <= p_due_date_to)
    and (p_requestor_id is null or r.requestor_id = p_requestor_id)
  order by v.requestor_name, v.due_date nulls last, v.cash_advance_reference_no;
$$;

-- ======================================
-- Notification queue helper: daily unliquidated digest per requestor
-- ======================================
create or replace function queue_daily_unliquidated_digest(
  p_scheduled_for timestamptz default now()
)
returns integer
language plpgsql
as $$
declare
  v_inserted_count integer;
begin
  with source_rows as (
    select
      s.requestor_id,
      s.requestor_name,
      s.unliquidated_balance,
      s.number_of_outstanding_requests,
      s.number_of_overdue_requests,
      (
        select jsonb_agg(
          jsonb_build_object(
            'cash_advance_reference_no', a.cash_advance_reference_no,
            'project_or_department', a.project_or_department,
            'due_date', a.due_date,
            'outstanding_amount', a.outstanding_amount,
            'aging_bucket', a.aging_bucket
          )
          order by a.due_date nulls last, a.cash_advance_reference_no
        )
        from v_report_aging_outstanding_unliquidated a
        join requests r2 on r2.request_no = a.cash_advance_reference_no
        where r2.requestor_id = s.requestor_id
          and a.outstanding_amount > 0
      ) as outstanding_items
    from v_report_unliquidated_summary_per_requestor s
    where s.unliquidated_balance > 0
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
      sr.requestor_id,
      'EMAIL'::notification_channel,
      'UNLIQUIDATED_DAILY_DIGEST',
      'Daily Unliquidated Cash Advance Summary',
      jsonb_build_object(
        'requestor_name', sr.requestor_name,
        'unliquidated_balance', sr.unliquidated_balance,
        'number_of_outstanding_requests', sr.number_of_outstanding_requests,
        'number_of_overdue_requests', sr.number_of_overdue_requests,
        'outstanding_items', coalesce(sr.outstanding_items, '[]'::jsonb),
        'reminder_message', 'Please liquidate or return outstanding balances as soon as possible.'
      ),
      'PENDING'::notification_status,
      p_scheduled_for
    from source_rows sr
    returning id
  )
  select count(*) into v_inserted_count from inserted;

  return coalesce(v_inserted_count, 0);
end;
$$;

-- ======================================
-- Notification queue helper: reminder before overdue (2 days)
-- ======================================
create or replace function queue_pre_overdue_reminders(
  p_scheduled_for timestamptz default now(),
  p_days_before_overdue integer default 2,
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
      and r.liquidation_due_date = (current_date + p_days_before_overdue)
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
      'PRE_OVERDUE_REMINDER',
      'Cash Advance Liquidation Reminder (Due Soon)',
      jsonb_build_object(
        'requestor_name', c.requestor_name,
        'cash_advance_reference_no', c.request_no,
        'due_date', c.liquidation_due_date,
        'outstanding_amount', c.outstanding_amount,
        'required_action', 'Please submit liquidation before due date.',
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
