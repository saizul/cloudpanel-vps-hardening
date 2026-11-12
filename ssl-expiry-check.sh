#!/usr/bin/env bash
# ssl-expiry-check.sh - warn when TLS certificates are close to expiry.
# Reads the certificate each listed host actually serves (openssl s_client), so it also catches
# a renewed certificate that Nginx never reloaded. Read-only; does not need root.
# Exit status: 0 all certificates fine, 1 one or more expiring, expired or unreachable.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

SSL_DOMAINS="${SSL_DOMAINS:-}"
SSL_WARN_DAYS="${SSL_WARN_DAYS:-21}"
SSL_TIMEOUT="${SSL_TIMEOUT:-10}"

usage() {
  cat <<USAGE
Usage: $0 [--dry-run] [--config FILE] [--days N] [HOST[:PORT] ...]
  HOST[:PORT]   hosts to check (default port 443); overrides SSL_DOMAINS from config.env
  --days N      warn when a certificate expires in fewer than N days (default: SSL_WARN_DAYS, 21)
  --quiet       print only warnings and errors (for cron: mail is sent only when there is a problem)
  --dry-run     print the openssl commands, make no connections
USAGE
}

cli_domains=""
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --config) CONFIG_FILE="${2:?}"; shift 2 ;;
    --quiet) QUIET=1; shift ;;
    --days) cli_days="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) cli_domains="$cli_domains $1"; shift ;;
  esac
done
if [ "$QUIET" -eq 1 ]; then load_config "$HERE" >/dev/null; else load_config "$HERE"; fi
SSL_WARN_DAYS="${cli_days:-$SSL_WARN_DAYS}"
[ -n "$cli_domains" ] && SSL_DOMAINS="$cli_domains"

case "$SSL_WARN_DAYS" in ''|*[!0-9]*) die "--days / SSL_WARN_DAYS must be a whole number, got '$SSL_WARN_DAYS'" ;; esac
is_uint "$SSL_TIMEOUT" && [ "$SSL_TIMEOUT" -gt 0 ] || die "SSL_TIMEOUT must be a positive whole number of seconds, got '$SSL_TIMEOUT'"
[ -n "${SSL_DOMAINS// /}" ] || die "no domains: pass HOST arguments or set SSL_DOMAINS in config.env"
command -v openssl >/dev/null 2>&1 || [ "$DRY_RUN" -eq 1 ] || die "openssl is required"

# "Jan  5 12:00:00 2027 GMT" (openssl notAfter) -> epoch seconds. GNU date first, BSD date second.
to_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%b %e %T %Y %Z' "$1" +%s 2>/dev/null
}

# Wrap a command in `timeout` when it exists so a silent host cannot hang the script.
with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout "$SSL_TIMEOUT" "$@"; else "$@"; fi
}

problems=0
now="$(date -u +%s)"
for target in $SSL_DOMAINS; do
  host="${target%%:*}"
  port=443
  case "$target" in *:*) port="${target##*:}" ;; esac
  case "$port" in ''|*[!0-9]*) err "$target: invalid port"; problems=$((problems + 1)); continue ;; esac

  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[DRY-RUN] openssl s_client -servername %q -connect %q:%s | openssl x509 -noout -enddate\n' "$host" "$host" "$port"
    continue
  fi

  cert="$(printf '' | with_timeout openssl s_client -servername "$host" -connect "$host:$port" 2>/dev/null \
    | openssl x509 -noout -enddate 2>/dev/null || true)"
  not_after="${cert#notAfter=}"
  if [ -z "$cert" ] || [ "$not_after" = "$cert" ]; then
    err "$host:$port: could not read a certificate (unreachable, no TLS, or timeout ${SSL_TIMEOUT}s)"
    problems=$((problems + 1))
    continue
  fi
  expires="$(to_epoch "$not_after" || true)"
  if [ -z "$expires" ]; then
    err "$host:$port: cannot parse expiry date '$not_after'"
    problems=$((problems + 1))
    continue
  fi

  days=$(( (expires - now) / 86400 ))
  if [ "$expires" -le "$now" ]; then
    err "$host:$port: certificate EXPIRED on $not_after"
    problems=$((problems + 1))
  elif [ "$days" -lt "$SSL_WARN_DAYS" ]; then
    warn "$host:$port: expires in $days day(s) ($not_after), below the $SSL_WARN_DAYS-day threshold"
    problems=$((problems + 1))
  else
    [ "$QUIET" -eq 1 ] || log "$host:$port: OK, $days day(s) left ($not_after)"
  fi
done

if [ "$DRY_RUN" -eq 1 ]; then [ "$QUIET" -eq 1 ] || log "dry run: no connections made"; exit 0; fi
if [ "$problems" -gt 0 ]; then warn "$problems certificate problem(s)"; exit 1; fi
[ "$QUIET" -eq 1 ] || log "all certificates are valid for at least $SSL_WARN_DAYS more day(s)"
