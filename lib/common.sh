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

load_config() {
  local here="$1" cfg="${CONFIG_FILE:-}"
  if [ -z "$cfg" ]; then
    if [ -f "$here/config.env" ]; then cfg="$here/config.env"; fi
  fi
  if [ -n "$cfg" ]; then
    [ -f "$cfg" ] || die "config file not found: $cfg"
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
