#!/usr/bin/env bash
# php-update-check.sh - list installed PHP-FPM versions, pending updates, EOL warnings.
# Read-only apart from `apt-get update` (skipped in --dry-run).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

usage() { echo "Usage: sudo $0 [--dry-run] [--config FILE]"; }
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
load_config "$HERE"
require_root

# Approximate end of security support (PHP.net). Update when versions change.
eol_date() {
  case "$1" in
    5.*|7.0|7.1|7.2|7.3|7.4|8.0) echo "EOL" ;;
    8.1) echo "2025-12-31" ;;
    8.2) echo "2026-12-31" ;;
    8.3) echo "2027-12-31" ;;
    8.4) echo "2028-12-31" ;;
    *)   echo "unknown" ;;
  esac
}

run apt-get update -qq

today="$(date +%F)"
found=0
for svc in $(systemctl list-unit-files --no-legend 'php*-fpm.service' 2>/dev/null | awk '{print $1}'); do
  ver="${svc#php}"; ver="${ver%-fpm.service}"
  found=1
  state="$(systemctl is-active "$svc" 2>/dev/null || true)"
  eol="$(eol_date "$ver")"
  printf 'PHP %-4s service=%-9s eol=%s\n' "$ver" "$state" "$eol"
  if [ "$eol" = "EOL" ] || { [ "$eol" != "unknown" ] && [[ "$today" > "$eol" ]]; }; then
    warn "PHP $ver is end-of-life: migrate sites to a supported version"
  elif [ "$eol" = "unknown" ]; then
    warn "PHP $ver: support status unknown to this script; check https://www.php.net/supported-versions.php"
  fi
done
[ "$found" -eq 1 ] || { log "no php*-fpm services found"; exit 0; }

log "pending upgrades for php packages:"
pending="$(apt list --upgradable 2>/dev/null | grep -E '^php[0-9.]*' || true)"
if [ -z "$pending" ]; then
  log "none"
else
  printf '%s\n' "$pending"
  sec="$(printf '%s\n' "$pending" | grep -i security || true)"
  if [ -n "$sec" ]; then warn "SECURITY updates pending for PHP packages (see lines above)"; fi
  log "apply with: sudo apt-get install --only-upgrade <package>  (then restart the matching phpX.Y-fpm)"
fi
