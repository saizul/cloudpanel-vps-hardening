#!/usr/bin/env bash
# Shared helpers. Sourced by every script; do not execute directly.
# shellcheck shell=bash

DRY_RUN=0
CONFIG_FILE=""

log()  { printf '%s [INFO ] %s\n' "$(date '+%F %T')" "$*"; }
warn() { printf '%s [WARN ] %s\n' "$(date '+%F %T')" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(date '+%F %T')" "$*" >&2; }
die()  { err "$*"; exit 1; }

require_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      warn "not root; continuing because --dry-run only prints commands"
    else
      die "must be run as root (try: sudo $0 ...)"
    fi
  fi
}

# Run a command, or only print it in dry-run mode.
run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[DRY-RUN]'; printf ' %q' "$@"; printf '\n'
    return 0
  fi
  "$@"
}

# Write stdin to a file (or print it in dry-run mode). Skips if content is unchanged.
write_file() {
  local dest="$1" mode="${2:-0644}" tmp
  tmp="$(mktemp)"
  cat >"$tmp"
  if [ -f "$dest" ] && cmp -s "$tmp" "$dest"; then
    log "unchanged: $dest"
    rm -f "$tmp"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[DRY-RUN] write %s (mode %s):\n' "$dest" "$mode"
    sed 's/^/    | /' "$tmp"
    rm -f "$tmp"
    return 0
  fi
  install -m "$mode" "$tmp" "$dest"
  rm -f "$tmp"
  log "wrote: $dest"
}

# Octal permission bits of a file (e.g. 644). GNU stat first, BSD stat second.
file_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

# True when group or others may write the file.
file_is_shared_writable() {
  local mode g o
  mode="$(file_mode "$1")" || return 1
  [ -n "$mode" ] || return 1
  mode="00$mode"; mode="${mode: -3}"
  g="${mode:1:1}"; o="${mode:2:1}"
  [ $(( (g & 2) | (o & 2) )) -ne 0 ]
}

load_config() {
  local here="$1" cfg="${CONFIG_FILE:-}"
  if [ -z "$cfg" ]; then
    if [ -f "$here/config.env" ]; then cfg="$here/config.env"; fi
  fi
  if [ -n "$cfg" ]; then
    [ -f "$cfg" ] || die "config file not found: $cfg"
    # The file is sourced (as root on a real run), so anyone who can write it can run code as root.
    if file_is_shared_writable "$cfg"; then
      die "refusing to load $cfg: it is writable by group or others (fix: chmod 600 $cfg)"
    fi
    # shellcheck disable=SC1090
    . "$cfg"
    log "loaded config: $cfg"
  else
    log "no config.env found; using built-in defaults (copy config.env.example to customise)"
  fi
}

check_ubuntu() {
  [ -r /etc/os-release ] || { warn "cannot read /etc/os-release"; return 0; }
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04) ;;
    *) warn "tested on Ubuntu 22.04/24.04 only; detected ${PRETTY_NAME:-unknown}" ;;
  esac
}

apt_install() {
  run env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

pkg_installed() { dpkg -s "$1" >/dev/null 2>&1; }

# ---- config validation -----------------------------------------------------
# Validators return 0 for a valid value. They are plain predicates so tests can call them directly.
# Bash 3.2 compatible on purpose (macOS /bin/bash), so the test suite runs on a laptop too.

has_newline() { case "$1" in *$'\n'*|*$'\r'*) return 0 ;; esac; return 1; }

is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }

is_port() { is_uint "$1" && [ "${#1}" -le 5 ] && [ "$((10#$1))" -ge 1 ] && [ "$((10#$1))" -le 65535 ]; }

# fail2ban time: 600, 10m, 1h30m, 1d, 1w; -1 means "forever" (bantime only, but harmless elsewhere).
is_f2b_time() {
  [ "$1" = "-1" ] && return 0
  [[ "$1" =~ ^([0-9]+[smhdw]?)+$ ]]
}

# fallocate size: 2G, 512M, 1048576 (bytes); not zero.
is_size() {
  [[ "$1" =~ ^[0-9]+[KMGT]?$ ]] && [[ ! "$1" =~ ^0+[KMGT]?$ ]]
}

# Redis memory: 256mb, 1gb, 100000 (bytes); case insensitive units as redis.conf accepts.
is_redis_memory() { [[ "$1" =~ ^[0-9]+([kKmMgG][bB]?)?$ ]]; }

is_redis_policy() {
  case "$1" in
    noeviction|allkeys-lru|allkeys-lfu|allkeys-random|volatile-lru|volatile-lfu|volatile-random|volatile-ttl) return 0 ;;
  esac
  return 1
}

# Linux account name as adduser accepts by default (NAME_REGEX), max 32 chars.
is_unix_user() { [ "${#1}" -le 32 ] && [[ "$1" =~ ^[a-z_][a-z0-9_-]*\$?$ ]]; }

# AllowUsers entry: USER or USER@HOST, with sshd wildcards (* ?) and CIDR hosts.
is_ssh_allow_entry() { [[ "$1" =~ ^[A-Za-z0-9_.*?-]+(@[A-Za-z0-9_.*?:/-]+)?$ ]]; }

is_ipv4() {
  local IFS=. o n=0
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  for o in $1; do
    [ "$((10#$o))" -le 255 ] || return 1
    n=$((n + 1))
  done
  [ "$n" -eq 4 ]
}

# Deliberately loose IPv6 shape check (hex groups, at most one ::); ufw rejects the rest.
is_ipv6() {
  [[ "$1" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  case "$1" in *:*) ;; *) return 1 ;; esac
  case "$1" in *:::*) return 1 ;; esac
  local rest="${1#*::}"
  case "$rest" in *::*) return 1 ;; esac
  return 0
}

# IP or CIDR, IPv4 (/0-32) or IPv6 (/0-128).
is_ip_or_cidr() {
  local addr="${1%/*}" bits=""
  case "$1" in */*) bits="${1#*/}"; [ -n "$bits" ] || return 1 ;; esac
  if is_ipv4 "$addr"; then
    [ -z "$bits" ] && return 0
    is_uint "$bits" && [ "${#bits}" -le 2 ] && [ "$((10#$bits))" -le 32 ]
  elif is_ipv6 "$addr"; then
    [ -z "$bits" ] && return 0
    is_uint "$bits" && [ "${#bits}" -le 3 ] && [ "$((10#$bits))" -le 128 ]
  else
    return 1
  fi
}

# One public key line for authorized_keys: TYPE BASE64 [comment]. Rejects private keys and options.
is_ssh_pubkey() {
  has_newline "$1" && return 1
  [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]{16,}={0,3}(\ .*)?$ ]]
}

# Timezone name: Area/City style, no path tricks; checked against zoneinfo when it is installed.
is_timezone() {
  [[ "$1" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  if [ -d "${ZONEINFO_DIR:-/usr/share/zoneinfo}" ]; then
    [ -f "${ZONEINFO_DIR:-/usr/share/zoneinfo}/$1" ] || return 1
  fi
  return 0
}

# Absolute path that is not / itself and has no .. components.
is_safe_abs_dir() {
  case "$1" in /*) ;; *) return 1 ;; esac
  has_newline "$1" && return 1
  [[ "$1" =~ ^/+$ ]] && return 1
  case "$1/" in */../*|*/./*) return 1 ;; esac
  return 0
}

# A value written into a config file line: single line, no spaces (redis requirepass, etc.).
is_single_token() { [ -n "$1" ] && ! has_newline "$1" && [[ ! "$1" =~ [[:space:]] ]]; }

CONFIG_ERRORS=0

config_error() {
  err "config: $*"
  CONFIG_ERRORS=$((CONFIG_ERRORS + 1))
}

# check_var NAME VALIDATOR HINT [optional]
#   Validates the variable named NAME with VALIDATOR; with "optional", an empty value is accepted.
check_var() {
  local name="$1" fn="$2" hint="$3" opt="${4:-}" val
  val="${!name-}"
  if [ -z "$val" ]; then
    [ "$opt" = "optional" ] && return 0
    config_error "$name is empty; expected $hint"
    return 0
  fi
  "$fn" "$val" || config_error "$name='$val' is invalid; expected $hint"
  return 0
}

# check_list NAME VALIDATOR HINT: every space separated word must pass (empty list is fine).
check_list() {
  local name="$1" fn="$2" hint="$3" item
  if has_newline "${!name-}"; then config_error "$name must be on one line"; return 0; fi
  for item in ${!name-}; do
    "$fn" "$item" || config_error "$name contains '$item'; expected $hint"
  done
  return 0
}

# Die listing every problem at once, or log success. Call after the check_* lines.
finish_config_check() {
  if [ "$CONFIG_ERRORS" -gt 0 ]; then
    die "$CONFIG_ERRORS config error(s); fix config.env (nothing was changed)"
  fi
  log "config OK"
}
