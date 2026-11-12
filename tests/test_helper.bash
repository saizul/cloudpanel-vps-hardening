# shellcheck shell=bash
# Shared setup for the bats suite. Tests never need root and never touch the system:
# scripts run with --check-config or --dry-run against a throwaway config file.

REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export REPO

setup() {
  TMP="$(mktemp -d "${BATS_TMPDIR:-/tmp}/vps-hardening.XXXXXX")"
  CFG="$TMP/config.env"
  export TMP CFG
  cp "$REPO/config.env.example" "$CFG"
  chmod 600 "$CFG"
}

teardown() {
  rm -rf "$TMP"
}

# Append KEY=VALUE lines to the test config (later assignments win when it is sourced).
set_cfg() {
  local kv
  for kv in "$@"; do printf '%s\n' "$kv" >>"$CFG"; done
}

# Source the helpers into the test shell (for the pure validators). lib/common.sh defines its own
# run(), which shadows bats' run, so use lib_call for anything that needs `run`.
load_lib() {
  # shellcheck source=lib/common.sh
  . "$REPO/lib/common.sh"
}

# lib_call FUNC ARGS...: call a lib/common.sh function in a fresh bash. DRY_RUN and CONFIG_FILE
# are taken from T_DRY_RUN / T_CONFIG_FILE because sourcing the library resets them.
lib_call() {
  bash -c '. "$REPO/lib/common.sh"; DRY_RUN="${T_DRY_RUN:-0}"; CONFIG_FILE="${T_CONFIG_FILE:-}"; "$@"' lib_call "$@"
}

# Assert that a command fails. (A bare `! cmd` does not fail a bats test: bash exempts
# negated commands from errexit.)
refute() {
  if "$@"; then
    printf 'expected failure, but succeeded: %s\n' "$*" >&2
    return 1
  fi
}
