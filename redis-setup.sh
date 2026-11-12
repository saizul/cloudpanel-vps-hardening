#!/usr/bin/env bash
# redis-setup.sh - install Redis bound to localhost with a memory cap (for WordPress object cache etc.).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

usage() { echo "Usage: sudo $0 [--dry-run] [--check-config] [--config FILE]"; }
CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --check-config) CHECK_ONLY=1; shift ;;
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done
load_config "$HERE"
: "${REDIS_MAXMEMORY:=256mb}" "${REDIS_POLICY:=allkeys-lru}" "${REDIS_PASSWORD:=}"
check_var REDIS_MAXMEMORY is_redis_memory "a size such as 256mb or 1gb"
check_var REDIS_POLICY is_redis_policy "a maxmemory-policy such as allkeys-lru or volatile-lru"
# The password is written verbatim after 'requirepass'; spaces or a newline would break redis.conf.
if [ -n "$REDIS_PASSWORD" ] && ! is_single_token "$REDIS_PASSWORD"; then
  config_error "REDIS_PASSWORD must be a single line without spaces"
fi
finish_config_check
[ "$CHECK_ONLY" -eq 0 ] || exit 0
require_root
check_ubuntu

pkg_installed redis-server || { run apt-get update; apt_install redis-server; }

# Drop-in-style: managed block appended once; avoids rewriting the packaged redis.conf.
conf=/etc/redis/redis.conf
begin='# BEGIN managed by redis-setup.sh'
end='# END managed by redis-setup.sh'
block="$begin
bind 127.0.0.1 -::1
protected-mode yes
maxmemory $REDIS_MAXMEMORY
maxmemory-policy $REDIS_POLICY"
if [ -n "$REDIS_PASSWORD" ]; then
  block="$block
requirepass $REDIS_PASSWORD"
fi
block="$block
$end"

if [ -f "$conf" ] && grep -qF "$begin" "$conf"; then
  current="$(sed -n "/$begin/,/$end/p" "$conf")"
  if [ "$current" = "$block" ]; then
    log "redis config already up to date"
  elif [ "$DRY_RUN" -eq 1 ]; then
    printf '[DRY-RUN] replace managed block in %s\n' "$conf"
  else
    sed -i "/$begin/,/$end/d" "$conf"
    printf '%s\n' "$block" >>"$conf"
    log "updated managed block"
    changed=1
  fi
elif [ "$DRY_RUN" -eq 1 ]; then
  printf '[DRY-RUN] append to %s (password redacted):\n' "$conf"
  printf '%s\n' "$block" | sed 's/^requirepass .*/requirepass ********/;s/^/    | /'
else
  cp -n "$conf" "$conf.orig" || true
  printf '\n%s\n' "$block" >>"$conf"
  log "appended managed block to $conf (original saved as $conf.orig)"
  changed=1
fi

run systemctl enable redis-server
if [ "${changed:-0}" -eq 1 ]; then
  run systemctl restart redis-server
else
  run systemctl start redis-server
fi

if [ "$DRY_RUN" -eq 0 ]; then
  if [ -n "$REDIS_PASSWORD" ]; then
    REDISCLI_AUTH="$REDIS_PASSWORD" redis-cli ping
  else
    redis-cli ping
  fi
fi
log "done. WordPress: install an object-cache plugin and set WP_REDIS_HOST=127.0.0.1 in wp-config.php."
