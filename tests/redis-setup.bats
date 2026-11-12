#!/usr/bin/env bats
# redis-setup.sh: config validation and dry run.

load test_helper

redis() { "$REPO/redis-setup.sh" --config "$CFG" "$@"; }

@test "--check-config accepts the shipped example config" {
  run redis --check-config
  [ "$status" -eq 0 ]
}

@test "invalid memory and policy are both reported" {
  set_cfg "REDIS_MAXMEMORY=lots" "REDIS_POLICY=lru"
  run redis --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"REDIS_MAXMEMORY='lots' is invalid"* ]]
  [[ "$output" == *"REDIS_POLICY='lru' is invalid"* ]]
  [[ "$output" == *"2 config error(s)"* ]]
}

@test "a password with spaces is rejected without echoing it" {
  set_cfg 'REDIS_PASSWORD="change me please"'
  run redis --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"REDIS_PASSWORD must be a single line without spaces"* ]]
  [[ "$output" != *"change me please"* ]]
}

@test "dry run redacts the password" {
  set_cfg 'REDIS_PASSWORD="placeholder-not-a-secret"'
  run redis --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"maxmemory 256mb"* ]]
  [[ "$output" == *"requirepass ********"* ]]
  [[ "$output" != *"placeholder-not-a-secret"* ]]
}
