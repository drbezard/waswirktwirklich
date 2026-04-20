#!/usr/bin/env bash
# ============================================================================
# Apply pending database migrations
#
# Iterates through supabase/migrations/*.sql in alphabetical order and applies
# any files that haven't been recorded in the public._migrations tracking
# table yet. Idempotent — safe to run multiple times.
#
# Requirements:
#   - psql installed
#   - DB_URL environment variable set (PostgreSQL connection string)
#
# Usage:
#   DB_URL="postgresql://..." ./apply-migrations.sh
# ============================================================================

set -euo pipefail

if [ -z "${DB_URL:-}" ]; then
  echo "::error::DB_URL environment variable is not set"
  exit 1
fi

MIGRATIONS_DIR="$(cd "$(dirname "$0")/../migrations" && pwd)"
echo "Migrations directory: $MIGRATIONS_DIR"

# Ensure tracking table exists. This is idempotent because the 004 migration
# uses CREATE TABLE IF NOT EXISTS.
psql "$DB_URL" -v ON_ERROR_STOP=1 -q -c "
  CREATE TABLE IF NOT EXISTS public._migrations (
    filename    text         PRIMARY KEY,
    applied_at  timestamptz  NOT NULL DEFAULT now(),
    checksum    text,
    applied_by  text
  );
" > /dev/null

# Get list of already applied migrations
APPLIED_LIST=$(psql "$DB_URL" -t -A -c "SELECT filename FROM public._migrations ORDER BY filename")

# Iterate through migration files in sorted order
APPLIED_COUNT=0
SKIPPED_COUNT=0

for migration_file in "$MIGRATIONS_DIR"/*.sql; do
  [ -f "$migration_file" ] || continue

  filename=$(basename "$migration_file")

  # Check if already applied
  if echo "$APPLIED_LIST" | grep -qx "$filename"; then
    echo "⊙ Skipping (already applied): $filename"
    SKIPPED_COUNT=$((SKIPPED_COUNT + 1))
    continue
  fi

  # Compute checksum for tracking
  checksum=$(sha256sum "$migration_file" | awk '{print $1}')

  echo "→ Applying: $filename (checksum: ${checksum:0:12}…)"

  # Apply migration and record it, all within a single transaction
  psql "$DB_URL" -v ON_ERROR_STOP=1 -1 -q -f "$migration_file"

  # Record in tracking table (outside the migration transaction to ensure
  # that if the migration itself does COMMIT/ROLLBACK, the record is still made)
  psql "$DB_URL" -v ON_ERROR_STOP=1 -q -c "
    INSERT INTO public._migrations (filename, checksum, applied_by)
    VALUES ('$filename', '$checksum', 'github_actions')
    ON CONFLICT (filename) DO UPDATE SET
      checksum = EXCLUDED.checksum,
      applied_at = now(),
      applied_by = EXCLUDED.applied_by;
  " > /dev/null

  echo "  ✓ Applied"
  APPLIED_COUNT=$((APPLIED_COUNT + 1))
done

echo ""
echo "Summary:"
echo "  ✓ Applied: $APPLIED_COUNT"
echo "  ⊙ Skipped: $SKIPPED_COUNT"

if [ "$APPLIED_COUNT" -gt 0 ]; then
  echo ""
  echo "::notice title=Migrations applied::$APPLIED_COUNT migration(s) applied successfully"
fi
