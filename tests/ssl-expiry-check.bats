#!/usr/bin/env bats
# ssl-expiry-check.sh: argument handling (dry run only, no network).

load test_helper

ssl() { "$REPO/ssl-expiry-check.sh" --config "$CFG" "$@"; }

@test "no domains is an error" {
  run ssl --dry-run
  [ "$status" -eq 1 ]
  [[ "$output" == *"no domains"* ]]
}

@test "dry run prints one openssl command per host and honours the port" {
  run ssl --dry-run example.com mail.example.com:465
  [ "$status" -eq 0 ]
  [[ "$output" == *"-connect example.com:443"* ]]
  [[ "$output" == *"-connect mail.example.com:465"* ]]
}

@test "SSL_DOMAINS from config is used when no hosts are given" {
  set_cfg 'SSL_DOMAINS="a.example b.example:8443"'
  run ssl --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"-connect a.example:443"* ]]
  [[ "$output" == *"-connect b.example:8443"* ]]
}

@test "--days must be a whole number" {
  run ssl --dry-run --days soon example.com
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be a whole number"* ]]
}

@test "SSL_TIMEOUT must be a positive number" {
  set_cfg "SSL_TIMEOUT=0"
  run ssl --dry-run example.com
  [ "$status" -eq 1 ]
  [[ "$output" == *"SSL_TIMEOUT must be a positive"* ]]
}

@test "invalid port is reported and the exit status is 1" {
  run ssl example.com:https
  [ "$status" -eq 1 ]
  [[ "$output" == *"example.com:https: invalid port"* ]]
}

@test "--quiet dry run prints only the commands" {
  run ssl --dry-run --quiet example.com
  [ "$status" -eq 0 ]
  [[ "$output" != *"[INFO ]"* ]]
  [[ "$output" == *"[DRY-RUN] openssl"* ]]
}
