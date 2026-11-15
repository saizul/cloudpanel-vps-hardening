#!/usr/bin/env bash
# audit.sh - read-only check that the hardening is actually in effect on this server.
# Compares the live state (effective sshd settings, ufw rules, fail2ban jail, kernel parameters,
# unattended upgrades, swap, NTP, accounts, Redis bind) with config.env and prints PASS/WARN/FAIL.
# Changes nothing. Run it as root for complete results; without root some checks are SKIPped.
# Exit status: 0 no FAIL (and no WARN with --strict), 1 otherwise or on a usage/config error.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

ALL_CHECKS="ssh ufw fail2ban sysctl updates swap time accounts redis"
CHECKS=""
QUIET=0
STRICT=0
CHECK_ONLY=0

# AUDIT_ROOT prefixes every file the audit reads (/etc/..., /proc/sys/..., /var/run/...).
# AUDIT_FIXTURES, when set, is a directory of saved command outputs used instead of running the
# commands (sshd-T, ufw-status, fail2ban-sshd, swapon, timedatectl). Both exist for the tests and
# for auditing a copy of a server's files offline.
AUDIT_ROOT="${AUDIT_ROOT:-}"
AUDIT_FIXTURES="${AUDIT_FIXTURES:-}"

usage() {
  cat <<USAGE
Usage: sudo $0 [options] [check ...]

Checks: $ALL_CHECKS   (default: all)
Options:
  --config FILE   config file (default: ./config.env if present)
  --only CHECKS   comma-separated checks to run
  --quiet         print only WARN and FAIL lines (for cron)
  --strict        exit 1 on warnings too
  --check-config  validate the settings the audit uses, then exit
  -h, --help      show help

Read-only: the audit never changes the server. Exit 0 = no failures, 1 = failures found.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_FILE="${2:?--config needs a file}"; shift 2 ;;
    --only)   CHECKS="${2//,/ }"; shift 2 ;;
    --quiet)  QUIET=1; shift ;;
    --strict) STRICT=1; shift ;;
    --check-config) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) CHECKS="$CHECKS $1"; shift ;;
  esac
done

if [ "$QUIET" -eq 1 ]; then load_config "$HERE" >/dev/null; else load_config "$HERE"; fi
: "${ADMIN_USER:=}" "${SSH_PORT:=22}" "${SSH_ALLOW_USERS:=}" "${UFW_PANEL_PORT:=}"
: "${UFW_PANEL_ALLOW:=}" "${TIMEZONE:=UTC}"

[ -n "${CHECKS// /}" ] || CHECKS="$ALL_CHECKS"

validate_config() {
  local c
  for c in $CHECKS; do
    case " $ALL_CHECKS " in *" $c "*) ;; *) config_error "unknown check: $c (valid: $ALL_CHECKS)" ;; esac
  done
  check_var SSH_PORT is_port "a TCP port 1-65535"
  check_var UFW_PANEL_PORT is_port "a TCP port 1-65535, e.g. 8443" optional
  check_list SSH_ALLOW_USERS is_ssh_allow_entry "USER or USER@HOST"
  check_list UFW_PANEL_ALLOW is_ip_or_cidr "IPv4/IPv6 addresses or CIDRs"
  check_var TIMEZONE is_timezone "a zone from 'timedatectl list-timezones', e.g. UTC"
  if [ "$CONFIG_ERRORS" -gt 0 ]; then
    die "$CONFIG_ERRORS config error(s); fix config.env"
  fi
  [ "$QUIET" -eq 1 ] || log "config OK"
}
validate_config
[ "$CHECK_ONLY" -eq 0 ] || exit 0

if [ "$(id -u)" -ne 0 ] && [ -z "$AUDIT_FIXTURES" ]; then
  warn "not root: checks that need root (sshd -T, ufw, fail2ban, /etc/shadow) are reported as SKIP"
fi

N_PASS=0; N_WARN=0; N_FAIL=0; N_SKIP=0

# result LEVEL CHECK MESSAGE
result() {
  local level="$1" check="$2"; shift 2
  case "$level" in
    PASS) N_PASS=$((N_PASS + 1)); [ "$QUIET" -eq 1 ] && return 0 ;;
    SKIP) N_SKIP=$((N_SKIP + 1)); [ "$QUIET" -eq 1 ] && return 0 ;;
    WARN) N_WARN=$((N_WARN + 1)) ;;
    FAIL) N_FAIL=$((N_FAIL + 1)) ;;
  esac
  printf '%-4s  %-9s %s\n' "$level" "$check" "$*"
}

# probe NAME CMD...: print a command's output, or the saved fixture NAME when AUDIT_FIXTURES is set.
# Returns non-zero when the command fails or the fixture is missing.
probe() {
  local name="$1"; shift
  if [ -n "$AUDIT_FIXTURES" ]; then
    [ -f "$AUDIT_FIXTURES/$name" ] || return 1
    cat "$AUDIT_FIXTURES/$name"
    return 0
  fi
  command -v "$1" >/dev/null 2>&1 || return 127
  "$@" 2>/dev/null
}

# True when the probe can run at all: a fixture directory is in use or the tool is installed.
probe_available() { [ -n "$AUDIT_FIXTURES" ] || command -v "$1" >/dev/null 2>&1; }

is_root_or_fixture() { [ -n "$AUDIT_FIXTURES" ] || [ "$(id -u)" -eq 0 ]; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# First value of KEY in the saved `sshd -T` output.
SSHD_OUT=""
sshd_value() { printf '%s\n' "$SSHD_OUT" | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }'; }

# ---- ssh -------------------------------------------------------------------
# Uses `sshd -T` (the effective configuration after all drop-ins), not the files, because the
# first value sshd reads wins and a later or earlier drop-in can silently undo the hardening.
check_ssh() {
  local out
  if ! probe_available sshd; then result SKIP ssh "sshd not installed"; return 0; fi
  if ! is_root_or_fixture; then result SKIP ssh "sshd -T needs root"; return 0; fi
  if ! out="$(probe sshd-T sshd -T)" || [ -z "$out" ]; then
    result FAIL ssh "sshd -T failed: the sshd configuration does not parse"; return 0
  fi
  SSHD_OUT="$(lower "$out")"; out="$SSHD_OUT"

  local key want got
  for key in "permitrootlogin no" "passwordauthentication no" "kbdinteractiveauthentication no" \
             "permitemptypasswords no" "pubkeyauthentication yes"; do
    want="${key#* }"; key="${key%% *}"
    got="$(sshd_value "$key")"
    if [ -z "$got" ] && [ "$key" = "kbdinteractiveauthentication" ]; then
      got="$(sshd_value challengeresponseauthentication)"  # OpenSSH < 8.7 name
    fi
    if [ "$got" = "$want" ]; then
      result PASS ssh "$key $got"
    else
      result FAIL ssh "$key is '${got:-unset}', expected '$want'"
    fi
  done

  # sshd -T prints one "port N" line per listening port.
  local ports
  ports="$(printf '%s\n' "$out" | awk '$1 == "port" { print $2 }' | tr '\n' ' ')"
  case " $ports " in
    *" $SSH_PORT "*) result PASS ssh "listening port includes SSH_PORT $SSH_PORT" ;;
    *) result FAIL ssh "sshd ports are '${ports% }', SSH_PORT is $SSH_PORT (ufw and sshd disagree)" ;;
  esac

  got="$(sshd_value maxauthtries)"
  if is_uint "$got" && [ "$got" -le 3 ]; then
    result PASS ssh "maxauthtries $got"
  else
    result WARN ssh "maxauthtries is '${got:-unset}', expected 3 or less"
  fi
  got="$(sshd_value x11forwarding)"
  if [ "$got" = "no" ]; then
    result PASS ssh "x11forwarding no"
  else
    result WARN ssh "x11forwarding is '${got:-unset}', expected 'no'"
  fi

  if [ -n "$SSH_ALLOW_USERS" ]; then
    got="$(printf '%s\n' "$out" | awk '$1 == "allowusers" { $1 = ""; sub(/^ /, ""); print }' | tr '\n' ' ')"
    local u missing=""
    for u in $SSH_ALLOW_USERS; do
      case " $got " in *" $(lower "$u") "*) ;; *) missing="$missing $u" ;; esac
    done
    if [ -z "$missing" ]; then
      result PASS ssh "allowusers matches SSH_ALLOW_USERS"
    else
      result FAIL ssh "allowusers is missing:$missing"
    fi
  fi
}

# ---- ufw -------------------------------------------------------------------
check_ufw() {
  local out
  if ! probe_available ufw; then result FAIL ufw "ufw is not installed"; return 0; fi
  if ! is_root_or_fixture; then result SKIP ufw "ufw status needs root"; return 0; fi
  if ! out="$(probe ufw-status ufw status verbose)"; then
    result FAIL ufw "ufw status failed"; return 0
  fi
  if ! printf '%s\n' "$out" | grep -q '^Status: active'; then
    result FAIL ufw "firewall is not active"; return 0
  fi
  result PASS ufw "firewall active"
  if printf '%s\n' "$out" | grep -Eq '^Default:.*deny \(incoming\)'; then
    result PASS ufw "default policy denies incoming"
  else
    result FAIL ufw "default incoming policy is not deny"
  fi
  # Rule lines look like: "22/tcp   ALLOW IN   Anywhere" or "8443/tcp ALLOW IN 203.0.113.10".
  if printf '%s\n' "$out" | grep -Eq "^${SSH_PORT}(/tcp)?[[:space:]].*ALLOW"; then
    result PASS ufw "SSH port $SSH_PORT allowed"
  else
    result FAIL ufw "no ALLOW rule for SSH port $SSH_PORT: a reboot or reload could lock you out"
  fi
  if [ -n "$UFW_PANEL_PORT" ]; then
    local panel
    panel="$(printf '%s\n' "$out" | grep -E "^${UFW_PANEL_PORT}(/tcp)?[[:space:]].*ALLOW" || true)"
    if [ -z "$panel" ]; then
      result WARN ufw "no ALLOW rule for panel port $UFW_PANEL_PORT"
    elif printf '%s\n' "$panel" | grep -Eq 'Anywhere'; then
      if [ -n "$UFW_PANEL_ALLOW" ]; then
        result FAIL ufw "panel port $UFW_PANEL_PORT is open to Anywhere although UFW_PANEL_ALLOW is set"
      else
        result WARN ufw "panel port $UFW_PANEL_PORT is open to Anywhere (set UFW_PANEL_ALLOW)"
      fi
    else
      result PASS ufw "panel port $UFW_PANEL_PORT restricted to an allow-list"
    fi
  fi
}

# ---- fail2ban --------------------------------------------------------------
check_fail2ban() {
  local out
  if ! probe_available fail2ban-client; then result FAIL fail2ban "fail2ban is not installed"; return 0; fi
  if ! is_root_or_fixture; then result SKIP fail2ban "fail2ban-client needs root"; return 0; fi
  if ! out="$(probe fail2ban-sshd fail2ban-client status sshd)"; then
    result FAIL fail2ban "sshd jail is not running (is the fail2ban service up?)"; return 0
  fi
  local banned
  banned="$(printf '%s\n' "$out" | awk -F: '/Currently banned/ { gsub(/[[:space:]]/, "", $2); print $2; exit }')"
  result PASS fail2ban "sshd jail running${banned:+, $banned IP(s) currently banned}"
}

# ---- sysctl ----------------------------------------------------------------
# Same keys and values that harden.sh writes to /etc/sysctl.d/99-hardening.conf.
SYSCTL_EXPECT="net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv6.conf.all.accept_source_route=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.log_martians=1
kernel.kptr_restrict=2
kernel.dmesg_restrict=1"

check_sysctl() {
  local line key want path got bad=0 missing=0
  while IFS= read -r line; do
    key="${line%%=*}"; want="${line#*=}"
    path="$AUDIT_ROOT/proc/sys/$(printf '%s' "$key" | tr . /)"
    if [ ! -r "$path" ]; then missing=$((missing + 1)); continue; fi
    got="$(tr -d '[:space:]' <"$path")"
    if [ "$got" != "$want" ]; then
      result FAIL sysctl "$key = $got, expected $want (run: harden.sh --only sysctl)"
      bad=$((bad + 1))
    fi
  done <<EOF
$SYSCTL_EXPECT
EOF
  if [ "$missing" -gt 0 ] && [ "$bad" -eq 0 ] && [ "$missing" -eq "$(printf '%s\n' "$SYSCTL_EXPECT" | wc -l | tr -d ' ')" ]; then
    result SKIP sysctl "no /proc/sys (not Linux?)"
  elif [ "$bad" -eq 0 ]; then
    local note=""
    [ "$missing" -eq 0 ] || note=" ($missing key(s) not present on this kernel)"
    result PASS sysctl "kernel network hardening in effect$note"
  fi
}

# ---- updates ---------------------------------------------------------------
check_updates() {
  local f="$AUDIT_ROOT/etc/apt/apt.conf.d/20auto-upgrades"
  if [ -f "$f" ] && grep -Eq '^[[:space:]]*APT::Periodic::Unattended-Upgrade[[:space:]]+"1"' "$f"; then
    result PASS updates "unattended security upgrades enabled"
  else
    result FAIL updates "unattended upgrades are not enabled (run: harden.sh --only updates)"
  fi
  if [ -f "$AUDIT_ROOT/var/run/reboot-required" ]; then
    result WARN updates "a reboot is required to finish installing updates"
  fi
}

# ---- swap ------------------------------------------------------------------
check_swap() {
  local out
  if ! probe_available swapon; then result SKIP swap "swapon not available"; return 0; fi
  out="$(probe swapon swapon --show --noheadings || true)"
  if [ -n "${out//[[:space:]]/}" ]; then
    result PASS swap "swap active"
  else
    result WARN swap "no active swap; memory spikes can trigger the OOM killer (run: harden.sh --only swap)"
  fi
}

# ---- time ------------------------------------------------------------------
check_time() {
  local out tz ntp
  if ! probe_available timedatectl; then result SKIP time "timedatectl not available"; return 0; fi
  if ! out="$(probe timedatectl timedatectl show)"; then result WARN time "timedatectl show failed"; return 0; fi
  tz="$(printf '%s\n' "$out" | sed -n 's/^Timezone=//p' | head -n 1)"
  ntp="$(printf '%s\n' "$out" | sed -n 's/^NTPSynchronized=//p' | head -n 1)"
  if [ "$ntp" = "yes" ]; then
    result PASS time "clock synchronised via NTP"
  else
    result WARN time "clock is not NTP synchronised (TLS, logs and TOTP depend on it)"
  fi
  if [ "$tz" = "$TIMEZONE" ]; then
    result PASS time "timezone $tz"
  else
    result WARN time "timezone is '${tz:-unknown}', TIMEZONE is '$TIMEZONE'"
  fi
}

# ---- accounts --------------------------------------------------------------
check_accounts() {
  local passwd="$AUDIT_ROOT/etc/passwd" shadow="$AUDIT_ROOT/etc/shadow" extra empty
  if [ ! -r "$passwd" ]; then result SKIP accounts "cannot read $passwd"; return 0; fi
  extra="$(awk -F: '$3 == 0 && $1 != "root" { printf "%s ", $1 }' "$passwd")"
  if [ -n "$extra" ]; then
    result FAIL accounts "accounts other than root with UID 0: ${extra% }"
  else
    result PASS accounts "only root has UID 0"
  fi
  if [ -n "$ADMIN_USER" ]; then
    if awk -F: -v u="$ADMIN_USER" '$1 == u { found = 1 } END { exit !found }' "$passwd"; then
      result PASS accounts "ADMIN_USER $ADMIN_USER exists"
    else
      result FAIL accounts "ADMIN_USER $ADMIN_USER does not exist (run: harden.sh --only user)"
    fi
  fi
  if [ -r "$shadow" ]; then
    empty="$(awk -F: '$2 == "" { printf "%s ", $1 }' "$shadow")"
    if [ -n "$empty" ]; then
      result FAIL accounts "accounts with an empty password: ${empty% }"
    else
      result PASS accounts "no account has an empty password"
    fi
  else
    result SKIP accounts "cannot read $shadow (needs root)"
  fi
}

# ---- redis -----------------------------------------------------------------
# Only when Redis is installed: it must listen on loopback only (redis-setup.sh does this).
check_redis() {
  local conf="$AUDIT_ROOT/etc/redis/redis.conf" bind addr bad=""
  if [ ! -f "$conf" ]; then result SKIP redis "not installed"; return 0; fi
  if [ ! -r "$conf" ]; then result SKIP redis "cannot read $conf (needs root)"; return 0; fi
  # The last bind line wins (redis-setup.sh appends its managed block at the end).
  bind="$(awk '$1 == "bind" { $1 = ""; line = $0 } END { print line }' "$conf")"
  for addr in $bind; do
    addr="${addr#-}"  # "-::1" means optional address
    case "$addr" in 127.*|::1|localhost) ;; *) bad="$bad $addr" ;; esac
  done
  if [ -z "${bind// /}" ]; then
    result FAIL redis "no bind directive: Redis listens on every interface"
  elif [ -n "$bad" ]; then
    result FAIL redis "bound to non-loopback address(es):$bad"
  else
    result PASS redis "bound to loopback only"
  fi
  if grep -Eq '^[[:space:]]*protected-mode[[:space:]]+no' "$conf"; then
    result WARN redis "protected-mode is off"
  fi
}

for c in $CHECKS; do
  "check_$c"
done

summary="audit: $N_PASS pass, $N_WARN warn, $N_FAIL fail, $N_SKIP skip"
if [ "$N_FAIL" -gt 0 ] || { [ "$STRICT" -eq 1 ] && [ "$N_WARN" -gt 0 ]; }; then
  warn "$summary"
  exit 1
fi
[ "$QUIET" -eq 1 ] || log "$summary"
