#!/usr/bin/env bash
# backup.sh - per-database MySQL/MariaDB dumps + per-site tarballs, retention, optional rclone.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

usage() { echo "Usage: sudo $0 [--dry-run] [--config FILE] [--skip-db] [--skip-files]"; }
SKIP_DB=0; SKIP_FILES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    --skip-db) SKIP_DB=1; shift ;;
    --skip-files) SKIP_FILES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
load_config "$HERE"
: "${BACKUP_DIR:=/var/backups/vps}" "${BACKUP_RETENTION_DAYS:=14}" "${SITES_DIR:=/home}"
: "${DB_EXCLUDE:=information_schema performance_schema sys mysql}" "${RCLONE_REMOTE:=}"
require_root

case "$BACKUP_RETENTION_DAYS" in ''|*[!0-9]*) die "BACKUP_RETENTION_DAYS must be a number" ;; esac

stamp="$(date +%Y%m%d-%H%M%S)"
dest="$BACKUP_DIR/$stamp"
run install -d -m 700 "$dest"
fail=0

if [ "$SKIP_DB" -eq 0 ]; then
  if command -v mysqldump >/dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      dbs="<each database from SHOW DATABASES, excluding: $DB_EXCLUDE>"
      log "databases: $dbs"
      printf '[DRY-RUN] mysqldump --single-transaction --routines <db> | gzip > %s/db-<db>.sql.gz\n' "$dest"
    else
      dbs="$(mysql -N -B -e 'SHOW DATABASES' 2>/dev/null)" || die "cannot list databases; set up /root/.my.cnf with [client] user/password"
      for db in $dbs; do
        skip=0
        for ex in $DB_EXCLUDE; do [ "$db" = "$ex" ] && skip=1; done
        [ "$skip" -eq 0 ] || continue
        log "dump: $db"
        if mysqldump --single-transaction --quick --routines --events "$db" | gzip >"$dest/db-$db.sql.gz"; then
          chmod 600 "$dest/db-$db.sql.gz"
        else
          err "dump failed: $db"; fail=1
        fi
      done
    fi
  else
    warn "mysqldump not found; skipping databases"
  fi
fi

if [ "$SKIP_FILES" -eq 0 ]; then
  if [ -d "$SITES_DIR" ] || [ "$DRY_RUN" -eq 1 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '[DRY-RUN] for each dir in %s/*: tar -czf %s/files-<name>.tar.gz -C %s <name>\n' "$SITES_DIR" "$dest" "$SITES_DIR"
    else
      for d in "$SITES_DIR"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        log "tar: $name"
        if tar -czf "$dest/files-$name.tar.gz" -C "$SITES_DIR" "$name" 2>/dev/null; then
          chmod 600 "$dest/files-$name.tar.gz"
        else
          err "tar failed: $name"; fail=1
        fi
      done
    fi
  else
    warn "SITES_DIR not found: $SITES_DIR"
  fi
fi

log "retention: removing backup sets older than $BACKUP_RETENTION_DAYS days in $BACKUP_DIR"
run find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*' -mtime "+$BACKUP_RETENTION_DAYS" -exec rm -rf {} +

if [ -n "$RCLONE_REMOTE" ]; then
  command -v rclone >/dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ] || die "rclone not installed but RCLONE_REMOTE is set"
  log "rclone copy to $RCLONE_REMOTE"
  run rclone copy "$dest" "$RCLONE_REMOTE/$stamp"
fi

if [ "$fail" -ne 0 ]; then die "finished with errors"; fi
log "backup complete: $dest"
