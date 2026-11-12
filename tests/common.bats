#!/usr/bin/env bats
# Unit tests for lib/common.sh.

load test_helper

@test "run: dry-run prints the shell-quoted command and does not execute it" {
  T_DRY_RUN=1 run lib_call run touch "$TMP/should not exist"
  [ "$status" -eq 0 ]
  [[ "$output" == "[DRY-RUN] touch "*"should\\ not\\ exist" ]]
  [ ! -e "$TMP/should not exist" ]
}

@test "run: executes the command when not in dry-run" {
  run lib_call run touch "$TMP/made"
  [ "$status" -eq 0 ]
  [ -f "$TMP/made" ]
}

@test "write_file: dry-run shows content and writes nothing" {
  T_DRY_RUN=1 run lib_call write_file "$TMP/out.conf" 0600 <<<"Port 2222"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] write $TMP/out.conf (mode 0600):"* ]]
  [[ "$output" == *"    | Port 2222"* ]]
  [ ! -e "$TMP/out.conf" ]
}

@test "write_file: writes with the requested mode, then reports unchanged" {
  run lib_call write_file "$TMP/out.conf" 0600 <<<"Port 2222"
  [ "$status" -eq 0 ]
  [[ "$output" == *"wrote: $TMP/out.conf"* ]]
  [ "$(cat "$TMP/out.conf")" = "Port 2222" ]
  run lib_call file_mode "$TMP/out.conf"
  [ "$output" = "600" ]
  run lib_call write_file "$TMP/out.conf" 0600 <<<"Port 2222"
  [[ "$output" == *"unchanged: $TMP/out.conf"* ]]
}

@test "write_file: replaces content that changed" {
  printf 'old\n' >"$TMP/out.conf"
  run lib_call write_file "$TMP/out.conf" 0644 <<<"new"
  [ "$status" -eq 0 ]
  [ "$(cat "$TMP/out.conf")" = "new" ]
}

@test "require_root: dry-run as non-root only warns" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  T_DRY_RUN=1 run lib_call require_root
  [ "$status" -eq 0 ]
  [[ "$output" == *"not root"* ]]
}

@test "require_root: real run as non-root dies" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  run lib_call require_root
  [ "$status" -eq 1 ]
  [[ "$output" == *"must be run as root"* ]]
}

@test "load_config: loads an explicit file" {
  set_cfg 'SSH_PORT=2222'
  # shellcheck disable=SC2016  # expanded by the inner shell
  T_CONFIG_FILE="$CFG" run lib_call eval 'load_config /nowhere && echo "port=$SSH_PORT"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"loaded config: $CFG"* ]]
  [[ "$output" == *"port=2222"* ]]
}

@test "load_config: auto-loads config.env next to the scripts" {
  set_cfg 'TIMEZONE=Europe/London'
  run lib_call eval "load_config '$TMP' && echo \"tz=\$TIMEZONE\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"tz=Europe/London"* ]]
}

@test "load_config: without a file uses defaults" {
  run lib_call load_config "$TMP/empty-dir"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no config.env found"* ]]
}

@test "load_config: missing file dies" {
  T_CONFIG_FILE="$TMP/missing.env" run lib_call load_config "$TMP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"config file not found"* ]]
}

@test "load_config: refuses a group-writable file and does not source it" {
  chmod 664 "$CFG"
  # shellcheck disable=SC2016  # expanded only if the file were sourced
  set_cfg 'touch "$TMP/sourced"'
  T_CONFIG_FILE="$CFG" run lib_call load_config "$TMP"
  [ "$status" -eq 1 ]
  [[ "$output" == *"writable by group or others"* ]]
  [ ! -e "$TMP/sourced" ]
}

@test "load_config: refuses a world-writable file" {
  chmod 646 "$CFG"
  T_CONFIG_FILE="$CFG" run lib_call load_config "$TMP"
  [ "$status" -eq 1 ]
}

@test "file_is_shared_writable: 600 and 644 are private, 620 and 602 are not" {
  load_lib
  chmod 600 "$CFG"; refute file_is_shared_writable "$CFG"
  chmod 644 "$CFG"; refute file_is_shared_writable "$CFG"
  chmod 620 "$CFG"; file_is_shared_writable "$CFG"
  chmod 602 "$CFG"; file_is_shared_writable "$CFG"
}

@test "is_uint / is_port" {
  load_lib
  is_uint 0; is_uint 42
  refute is_uint ""; refute is_uint -1; refute is_uint 1.5; refute is_uint "1 2"
  is_port 1; is_port 22; is_port 8443; is_port 65535
  refute is_port 0; refute is_port 65536; refute is_port 123456; refute is_port ssh; refute is_port ""
}

@test "is_f2b_time" {
  load_lib
  is_f2b_time 600; is_f2b_time 10m; is_f2b_time 1h30m; is_f2b_time 1d; is_f2b_time 1w; is_f2b_time -1
  refute is_f2b_time ""; refute is_f2b_time 10x; refute is_f2b_time "10 m"; refute is_f2b_time -5; refute is_f2b_time m
}

@test "is_size" {
  load_lib
  is_size 2G; is_size 512M; is_size 1048576; is_size 1T
  refute is_size 0; refute is_size 0G; refute is_size 2g; refute is_size 2GB; refute is_size ""; refute is_size "-1G"
}

@test "is_redis_memory / is_redis_policy" {
  load_lib
  is_redis_memory 256mb; is_redis_memory 1gb; is_redis_memory 1GB; is_redis_memory 100000; is_redis_memory 512m
  refute is_redis_memory ""; refute is_redis_memory "256 mb"; refute is_redis_memory 1tb; refute is_redis_memory lots
  is_redis_policy allkeys-lru; is_redis_policy noeviction; is_redis_policy volatile-ttl
  refute is_redis_policy lru; refute is_redis_policy ""; refute is_redis_policy "allkeys-lru x"
}

@test "is_unix_user" {
  load_lib
  is_unix_user deploy; is_unix_user _svc; is_unix_user web-admin_2
  refute is_unix_user Deploy; refute is_unix_user 1user; refute is_unix_user "a b"; refute is_unix_user "root ALL"
  refute is_unix_user "$(printf 'a%.0s' {1..33})"
  refute is_unix_user "$(printf 'deploy\nevil')"
}

@test "is_ssh_allow_entry" {
  load_lib
  is_ssh_allow_entry deploy; is_ssh_allow_entry 'deploy@203.0.113.*'; is_ssh_allow_entry 'ops@10.0.0.0/8'
  refute is_ssh_allow_entry 'deploy;rm'; refute is_ssh_allow_entry ''
}

@test "is_ip_or_cidr: IPv4" {
  load_lib
  is_ip_or_cidr 203.0.113.10; is_ip_or_cidr 198.51.100.0/24; is_ip_or_cidr 0.0.0.0/0; is_ip_or_cidr 10.0.0.1/32
  refute is_ip_or_cidr 256.1.1.1; refute is_ip_or_cidr 1.2.3; refute is_ip_or_cidr 1.2.3.4.5; refute is_ip_or_cidr 1.2.3.4/33
  refute is_ip_or_cidr 1.2.3.4/; refute is_ip_or_cidr example.com; refute is_ip_or_cidr ""
}

@test "is_ip_or_cidr: IPv6" {
  load_lib
  is_ip_or_cidr 2001:db8::1; is_ip_or_cidr 2001:db8::/32; is_ip_or_cidr ::1; is_ip_or_cidr fe80::/10
  refute is_ip_or_cidr 2001:db8::1::2; refute is_ip_or_cidr 2001:db8:::1; refute is_ip_or_cidr 2001:db8::/129; refute is_ip_or_cidr gggg::1
}

@test "is_ssh_pubkey" {
  load_lib
  is_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExample you@laptop"
  is_ssh_pubkey "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleExampleExampleExampleExample"
  is_ssh_pubkey "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTY= host"
  refute is_ssh_pubkey "-----BEGIN OPENSSH PRIVATE KEY-----"
  refute is_ssh_pubkey "ssh-ed25519"
  refute is_ssh_pubkey "ssh-dss AAAAB3NzaC1kc3MAAACBAExampleExample"
  refute is_ssh_pubkey 'from="1.2.3.4" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample'
  refute is_ssh_pubkey "$(printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOther')"
}

@test "is_timezone: checks names against a zoneinfo directory" {
  load_lib
  mkdir -p "$TMP/zi/Europe"; touch "$TMP/zi/UTC" "$TMP/zi/Europe/London"
  export ZONEINFO_DIR="$TMP/zi"
  is_timezone UTC; is_timezone Europe/London
  refute is_timezone Europe/Nowhere; refute is_timezone ../../etc/passwd; refute is_timezone "UTC "; refute is_timezone ""
}

@test "is_safe_abs_dir" {
  load_lib
  is_safe_abs_dir /var/backups/vps; is_safe_abs_dir /home; is_safe_abs_dir /home/
  refute is_safe_abs_dir /; refute is_safe_abs_dir //; refute is_safe_abs_dir relative/dir; refute is_safe_abs_dir ""
  refute is_safe_abs_dir /var/../etc; refute is_safe_abs_dir /var/./backups
}

@test "is_single_token" {
  load_lib
  is_single_token 's3cr3t-Placeholder!'
  refute is_single_token ""; refute is_single_token "two words"; refute is_single_token "$(printf 'a\nb')"
}

@test "check_var / check_list: collect every error, then finish_config_check dies once" {
  run bash -c '
    . "$REPO/lib/common.sh"
    SSH_PORT=99999 UFW_PANEL_PORT="" SWAP_SIZE="" UFW_PANEL_ALLOW="1.2.3.4 nope 10.0.0.0/99"
    check_var SSH_PORT is_port "a port"
    check_var UFW_PANEL_PORT is_port "a port" optional
    check_var SWAP_SIZE is_size "a size"
    check_list UFW_PANEL_ALLOW is_ip_or_cidr "IPs"
    finish_config_check
    echo "not reached"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"SSH_PORT='99999' is invalid"* ]]
  [[ "$output" == *"SWAP_SIZE is empty"* ]]
  [[ "$output" == *"contains 'nope'"* ]]
  [[ "$output" == *"contains '10.0.0.0/99'"* ]]
  [[ "$output" != *"UFW_PANEL_PORT"* ]]
  [[ "$output" == *"4 config error(s)"* ]]
  [[ "$output" != *"not reached"* ]]
}

@test "finish_config_check: passes when there are no errors" {
  run lib_call eval 'SSH_PORT=22; check_var SSH_PORT is_port "a port"; finish_config_check'
  [ "$status" -eq 0 ]
  [[ "$output" == *"config OK"* ]]
}
