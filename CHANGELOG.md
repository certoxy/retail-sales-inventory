# Changelog

## [1.2.0] - 2026-08-26

### Added

- Receipt-number lookup for returns
- Partial item and quantity returns with over-return prevention
- Refund and exchange outcomes
- Sellable, damaged and expired dispositions
- Administrator approval and rejection workflow
- Automatic restocking only for approved sellable returns
- Permanent return audit history and printable return receipts

## [1.1.0] - 2026-08-26

### Added

- Automatic receipt preview after completed checkout
- 58 mm and 80 mm thermal-printer layouts
- Branch, cashier, transaction, payment and VAT receipt details
- Sales History workspace with the latest 100 permitted transactions
- Permission-aware receipt retrieval and reprinting

## [1.0.0] - 2026-08-26

### Added

- Date-range and branch-filtered sales dashboard
- Net sales, transaction count, average sale and estimated gross profit KPIs
- Daily sales trend and payment-method mix
- Top-selling products and branch-performance tables
- Low-stock, expiry, open-order and in-transit operational indicators
- CSV export of filtered sales transactions
- Cashier-scoped reporting with administrator-only profit visibility

## [0.9.0] - 2026-08-26

### Added

- Supplier records with contact details
- Branch-specific purchase orders and multiple order lines
- Full and partial delivery receiving
- Automatic stock and latest-cost updates from received deliveries
- Optional lot numbers and expiration dates
- Expired and 30-day expiry monitoring
- FEFO lot reduction during sales and lot preservation during stock transfers

## [0.8.0] - 2026-08-25

### Added

- Multi-product branch-to-branch stock transfers
- In-transit and received transfer states
- Destination receipt confirmation before inventory increases
- Transfer-out and transfer-in inventory audit movements
- Transfer history with route, item and status details

## [0.7.1] - 2026-08-25

### Fixed

- Multi-branch migration now drops and recreates the inventory movement view when adding branch columns
- Migration is wrapped in an explicit transaction to prevent partial schema changes

## [0.7.0] - 2026-08-25

### Added

- Branch records and branch selector
- Branch-specific product prices, inventory and reorder levels
- Branch-aware checkout and stock adjustments
- Multi-branch cashier assignments
- Main Branch migration for existing inventory and transactions

### Security

- Branch-aware Row-Level Security and transactional functions

## [0.6.0] - 2026-08-25

### Added

- Duplicate-safe internal Code 128 barcode generation
- Live barcode preview
- Individual and batch product label selection
- Print-ready labels with product name, price, barcode and SKU
- Barcode generator database migration

## [0.5.0] - 2026-08-25

### Added

- Product editing
- Product activation and deactivation
- Barcode capture and checkout search
- Product-specific reorder-level alerts
- Cost, markup and potential-margin reporting

### Changed

- Inactive products remain in the administrator catalogue but are excluded from checkout

## [0.4.0] - 2026-08-25

### Added

- Administrator and cashier roles
- Automatic cashier profile creation for new users
- Staff role and activation management
- Role-aware navigation
- Administrator-only inventory functions and policies

## [0.3.0] - 2026-08-25

### Added

- Products and Inventory workspace
- Product creation
- Stock receiving and inventory adjustments
- Low-stock summaries and stock movement history
- Secure `change_stock` function

## [0.2.0] - 2026-08-25

### Added

- Supabase email/password authentication
- Live product retrieval and atomic checkout
- Automatic stock deduction
- Row-Level Security
- Initial retail schema and sample products

## [0.1.0] - 2026-08-25

### Added

- Interactive retail checkout prototype
- Product search and cart controls
- VAT-inclusive total
- Cash, card and GCash options
- Responsive interface
