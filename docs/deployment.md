# Deployment

## Runtime configuration

The application requires:

- `NEXT_PUBLIC_SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`

The publishable key is intended for client applications. Access remains governed by Authentication and Row-Level Security. Never expose a service-role key in the browser.

## Environments

Use separate Supabase projects for development and production before real store data is introduced. Apply the same numbered migrations to each environment in order.

## Release procedure

1. Update source and documentation.
2. Add a new migration if the database changes.
3. Confirm environment variables.
4. Build and deploy the verified version.
5. Smoke-test sign-in, product loading, checkout and stock history.
6. Record the release in `CHANGELOG.md`.

## Rollback

Application versions can be rolled back independently. Database migrations should be forward-fixed with a new migration; do not edit migrations already applied to production.
