#!/usr/bin/env bash
set -euo pipefail

# Full project backup helper:
# 1) source code tar.gz
# 2) postgres schema+data dump
# 3) storage metadata export
#
# Connection modes:
# A) DATABASE_URL
# B) PGHOST, PGPORT, PGDATABASE, PGUSER, PGPASSWORD

BACKUP_DIR="${BACKUP_DIR:-./backups}"
PROJECT_ROOT="${PROJECT_ROOT:-.}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT_DIR="$BACKUP_DIR/$STAMP"
mkdir -p "$OUT_DIR"

DB_CONNECT=()
if [[ -n "${DATABASE_URL:-}" ]]; then
  DB_CONNECT=("$DATABASE_URL")
else
  : "${PGHOST:?Set DATABASE_URL or PGHOST}"
  : "${PGPORT:?Set DATABASE_URL or PGPORT}"
  : "${PGDATABASE:?Set DATABASE_URL or PGDATABASE}"
  : "${PGUSER:?Set DATABASE_URL or PGUSER}"
  : "${PGPASSWORD:?Set DATABASE_URL or PGPASSWORD}"
  DB_CONNECT=("host=$PGHOST" "port=$PGPORT" "dbname=$PGDATABASE" "user=$PGUSER" "sslmode=${PGSSLMODE:-require}")
fi

echo "[1/4] Backup source project..."
tar --exclude='.git' -czf "$OUT_DIR/project-files.tar.gz" -C "$PROJECT_ROOT" .

echo "[2/4] Backup postgres schema..."
pg_dump "${DB_CONNECT[@]}" --schema-only --no-owner --no-privileges > "$OUT_DIR/db-schema.sql"

echo "[3/4] Backup postgres data..."
pg_dump "${DB_CONNECT[@]}" --data-only --inserts --no-owner --no-privileges > "$OUT_DIR/db-data.sql"

echo "[4/4] Backup storage metadata (no file content)..."
psql "${DB_CONNECT[@]}" -Atc "copy (
  select bucket_id, name, owner, created_at, updated_at, metadata
  from storage.objects
  order by bucket_id, name
) to stdout with csv header" > "$OUT_DIR/storage-objects.csv"

echo "Backup finished: $OUT_DIR"
