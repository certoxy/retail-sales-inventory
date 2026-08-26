# Retail Sales and Inventory

A browser-based retail point-of-sale and inventory application built with React/Vinext and Supabase. The current MVP supports authenticated checkout, automatic stock deduction, product creation, stock receiving, inventory adjustments, low-stock monitoring, and a stock movement audit trail.

## Current features

- Email and password authentication through Supabase
- Product search and point-of-sale cart
- Cash, card, and GCash payment methods
- VAT-inclusive transaction totals
- Atomic sale completion and stock deduction
- Product and category creation
- Product editing, activation and barcode support
- Automatic Code 128 barcode generation and printable labels
- Stock receiving and positive/negative adjustments
- Administrator and cashier roles
- Staff activation and role management
- Multiple branches with branch-specific pricing and inventory
- Multi-branch staff assignments and branch-aware checkout
- Confirmed multi-item stock transfers between branches
- Supplier records, purchase orders and partial delivery receiving
- Optional lot/batch and expiry-date inventory with FEFO consumption
- Sales and operations dashboard with branch and date filters
- Payment mix, top-product and branch-performance reporting
- Administrator-only estimated gross profit and CSV sales export
- Automatic checkout receipts and sales-history reprinting
- Thermal-printer layouts for 58 mm and 80 mm paper
- Partial returns, refund/exchange requests and administrator approval
- Sellable, damaged and expired return dispositions with audit receipts
- Cashier shifts with opening float, drawer movements and closing reconciliation
- Payment-method totals, cash over/short reporting and administrator shift review
- Branch stocktakes with physical counts, variance review and controlled posting
- Automated reorder suggestions, preferred suppliers and supplier-grouped draft orders
- Critical-stock pop-up alerts for branch administrators
- Branch expense tracking with approvals, CSV export and cashier-shift cash integration
- Dashboard operating-result estimates after approved expenses
- Damaged, expired, spoiled, missing, recalled and store-use inventory write-offs
- Lot-aware disposal approval, automatic stock deduction and loss reporting
- Protection against negative inventory
- Low-stock indicators and inventory summaries
- Cost, markup and potential-margin visibility for administrators
- Sales, sale-item, and stock-movement history
- Responsive desktop and mobile interface

## Technology

- React 19 and TypeScript
- Vinext/Vite
- Supabase Postgres, Authentication, Row-Level Security and RPC functions
- OpenAI Sites hosting

## Setup

### 1. Clone and install

```bash
git clone https://github.com/certoxy/retail-sales-inventory.git
cd retail-sales-inventory
npm install
```

Node.js 22.13 or newer is required.

### 2. Configure Supabase

Copy `.env.example` to `.env.local` and enter:

```env
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=your-publishable-key
```

Never commit `.env.local`, passwords, service-role keys, or other secrets.

### 3. Run database migrations

Run the SQL files in Supabase SQL Editor in numeric order:

1. `supabase/migrations/001_initial_retail_schema.sql`
2. `supabase/migrations/002_inventory_management.sql`
3. `supabase/migrations/003_staff_roles.sql`
4. `supabase/migrations/004_barcode_generation.sql`
5. `supabase/migrations/005_multibranch_foundation.sql`
6. `supabase/migrations/006_stock_transfers.sql`
7. `supabase/migrations/007_suppliers_purchase_orders_expiry.sql`
8. `supabase/migrations/008_sales_dashboard.sql`
9. `supabase/migrations/009_receipt_printing.sql`
10. `supabase/migrations/010_returns_refunds.sql`
11. `supabase/migrations/011_cashier_shifts.sql`
12. `supabase/migrations/012_stocktake_physical_count.sql`
13. `supabase/migrations/013_reorder_suggestions.sql`
14. `supabase/migrations/014_branch_expenses.sql`
15. `supabase/migrations/015_inventory_disposals.sql`

Then create at least one user under **Supabase → Authentication → Users**.

### 4. Start locally

```bash
npm run dev
```

## Documentation

- [Architecture](docs/architecture.md)
- [Database](docs/database.md)
- [Deployment](docs/deployment.md)
- [Roadmap](docs/roadmap.md)
- [Changelog](CHANGELOG.md)

## Security

All application tables use Row-Level Security. Database access is limited to authenticated users. Checkout and stock adjustments are database functions so related changes succeed or fail as one transaction.

## Status

Version 1.7 includes the complete branch disposal and write-off workflow. Offline support and automated tests remain before production retail use.
