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

This is an early working MVP. It still needs reporting, customer management, purchasing, offline support and automated tests before production retail use.
