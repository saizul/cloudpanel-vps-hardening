#!/usr/bin/env bats
# backup.sh: config validation and dry run.

load test_helper

backup() { "$REPO/backup.sh" --config "$CFG" "$@"; }

@test "--check-config accepts the shipped example config" {
  run backup --check-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"config OK"* ]]
}

@test "BACKUP_DIR=/ is rejected (retention runs rm -rf under it)" {
  set_cfg "BACKUP_DIR=/"
  run backup --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"BACKUP_DIR='/' is invalid"* ]]
}

@test "relative or dot-dot directories are rejected" {
  set_cfg "BACKUP_DIR=backups" "SITES_DIR=/home/../etc"
  run backup --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"BACKUP_DIR='backups' is invalid"* ]]
  [[ "$output" == *"SITES_DIR='/home/../etc' is invalid"* ]]
}

@test "non-numeric retention is rejected" {
  set_cfg "BACKUP_RETENTION_DAYS=two-weeks"
  run backup --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"BACKUP_RETENTION_DAYS='two-weeks' is invalid"* ]]
}

@test "RCLONE_REMOTE must look like REMOTE:PATH or an absolute path" {
  set_cfg 'RCLONE_REMOTE="my-bucket/vps"'
  run backup --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"RCLONE_REMOTE="* ]]
  set_cfg 'RCLONE_REMOTE="b2:my-bucket/vps"'
  run backup --check-config
  [ "$status" -eq 0 ]
  set_cfg 'RCLONE_REMOTE="/mnt/offsite"'
  run backup --check-config
  [ "$status" -eq 0 ]
}

@test "BACKUP_DIR inside SITES_DIR warns" {
  set_cfg "BACKUP_DIR=/home/backups" "SITES_DIR=/home"
  run backup --check-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"BACKUP_DIR is inside SITES_DIR"* ]]
}

@test "dry run prints the plan and writes nothing" {
  set_cfg "BACKUP_DIR=$TMP/backups" "SITES_DIR=$TMP/sites"
  run backup --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] install -d -m 700 $TMP/backups/"* ]]
  [[ "$output" == *"mysqldump --single-transaction"* ]]
  [[ "$output" == *"tar -czf $TMP/backups/"* ]]
  [ ! -e "$TMP/backups" ]
}

@test "--skip-db --skip-files leaves only retention in the dry run" {
  set_cfg "BACKUP_DIR=$TMP/backups"
  run backup --dry-run --skip-db --skip-files
  [ "$status" -eq 0 ]
  [[ "$output" != *"mysqldump"* ]]
  [[ "$output" != *"tar -czf"* ]]
  [[ "$output" == *"[DRY-RUN] find $TMP/backups"* ]]
}
