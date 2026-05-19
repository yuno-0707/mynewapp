# RCAMS MVP (Phase 10.1)

Beginner-friendly MVP web app for Requisition and Cash Advance Management.

## Stack
- Frontend: React + Vite
- Backend: Node.js + Express
- DB: PostgreSQL
- DB driver: pg

## 1) Prerequisites
- Node 18+
- Docker
- psql client

## 2) Environment
Copy env:
```bash
cp .env.example .env
```

Default DB connection:
- Host: localhost
- Port: 5432
- DB: rcams
- User: postgres
- Password: postgres

## 3) Start PostgreSQL (Codespaces)
```bash
docker start rcams-pg || docker run --name rcams-pg -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=rcams -p 5432:5432 -d postgres:16
```

## 4) Recreate DB from empty DB (baseline lock)
```bash
dropdb --if-exists -h localhost -U postgres rcams
createdb -h localhost -U postgres rcams

psql "postgresql://postgres:postgres@localhost:5432/rcams" -f sql/schema.sql
psql "postgresql://postgres:postgres@localhost:5432/rcams" -f sql/phase2_seed_and_functions.sql
psql "postgresql://postgres:postgres@localhost:5432/rcams" -f sql/phase3_approval_actions.sql
psql "postgresql://postgres:postgres@localhost:5432/rcams" -f sql/phase4_cash_advance_and_liquidation.sql
psql "postgresql://postgres:postgres@localhost:5432/rcams" -f sql/phase5_reporting_and_notifications.sql
psql "postgresql://postgres:postgres@localhost:5432/rcams" -f sql/phase6_security_rls_and_constraints.sql
psql "postgresql://postgres:postgres@localhost:5432/rcams" -f sql/phase7_operational_automation.sql
psql "postgresql://postgres:postgres@localhost:5432/rcams" -f sql/phase8_quality_assurance_and_release.sql
psql "postgresql://postgres:postgres@localhost:5432/rcams" -f sql/phase9_integration_test_pack.sql
```

## 5) Install and seed
```bash
npm install
npm run seed
```

## 6) Run app
```bash
npm run dev
```
- Frontend: http://localhost:5173
- API: http://localhost:3001

Open port **5173** in Codespaces.

## 7) Test logins
Use email only in MVP login page:
- admin@rcams.local
- requestor@rcams.local
- approver@rcams.local
- finance@rcams.local

## 8) Test flow (end-to-end)
1. Login as `requestor@rcams.local`.
2. Go to **Create Request**:
   - choose request type/payment type,
   - choose project (or department),
   - choose CE item for project requests,
   - enter amount and due date,
   - click **Create + Submit**.
3. Login as `approver@rcams.local` → **Approval Inbox** → Approve.
4. Login as `finance@rcams.local` → **Cash Advance Release** → Release.
5. Login as `requestor@rcams.local` → **Liquidation**:
   - select request,
   - enter actual total,
   - enter returned amount/reference,
   - click **Submit Liquidation**.
6. Login as `approver@rcams.local` → **Approval Inbox** → Approve liquidation.
7. Check **Reports** page and export CSV.
## 8) Workflow test (quick)
1. Login as `requestor@rcams.local`.
2. Go to **Create Request** and create/submit request.
3. Login as `approver@rcams.local` → **Approval Inbox** → Approve.
4. Login as `finance@rcams.local` → **Cash Advance Release** → Release.
5. Login as requestor → **Liquidation** → Submit liquidation.
6. Login as approver → **Approval Inbox** → Approve liquidation.
7. (Optional API call) finalize liquidation endpoint if needed.
8. Go to **Reports** and load Aging/Overdue/Project totals; export CSV.

## 9) Worker
Run daily jobs + simulated dev email sender:
```bash
npm run worker
```

## 10) Security UAT checks
- Requestor: should only process own request workflow.
- Approver: should process approvals.
- Finance: should release cash advances and handle liquidation flow.
- Admin: should access users/masterlists pages.

## API response format
Success:
```json
{ "success": true, "data": {} }
```
Error:
```json
{ "success": false, "error": { "message": "Error message", "code": "ERROR_CODE" } }
```
