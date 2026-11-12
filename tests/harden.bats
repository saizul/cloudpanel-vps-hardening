#!/usr/bin/env bats
# harden.sh: argument handling and config validation. No root needed, nothing is changed.

load test_helper

KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExamplePlaceholderKeyMaterialOnly you@laptop"

harden() { "$REPO/harden.sh" --config "$CFG" "$@"; }

@test "--help prints usage and exits 0" {
  run harden --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]
  [[ "$output" == *"--check-config"* ]]
}

@test "unknown option fails" {
  run harden --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown option: --bogus"* ]]
}

@test "--check-config accepts the shipped example config" {
  run harden --check-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"config OK"* ]]
}

@test "--check-config accepts a fully populated valid config" {
  set_cfg "ADMIN_USER=deploy" "ADMIN_SSH_PUBKEY=\"$KEY\"" "SSH_PORT=2222" \
    'SSH_ALLOW_USERS="deploy ops@203.0.113.*"' "UFW_PANEL_PORT=8443" \
    'UFW_PANEL_ALLOW="203.0.113.10 198.51.100.0/24 2001:db8::/32"' "F2B_BANTIME=-1" "SWAP_SIZE=4G"
  run harden --check-config
  [ "$status" -eq 0 ]
}

@test "--check-config reports every invalid value at once" {
  set_cfg "SSH_PORT=70000" 'UFW_PANEL_ALLOW="203.0.113.10 office"' "UFW_PANEL_PORT=8443" \
    "F2B_FINDTIME=ten" "SWAP_SIZE=2GB" "TIMEZONE=Mars/Olympus"
  run harden --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"SSH_PORT='70000' is invalid"* ]]
  [[ "$output" == *"UFW_PANEL_ALLOW contains 'office'"* ]]
  [[ "$output" == *"F2B_FINDTIME='ten' is invalid"* ]]
  [[ "$output" == *"SWAP_SIZE='2GB' is invalid"* ]]
  [[ "$output" == *"TIMEZONE='Mars/Olympus' is invalid"* ]]
  [[ "$output" == *"5 config error(s)"* ]]
}

@test "rejects an ADMIN_USER that would corrupt the sudoers drop-in" {
  set_cfg 'ADMIN_USER="deploy ALL=(ALL) NOPASSWD:ALL"' "ADMIN_SSH_PUBKEY=\"$KEY\""
  run harden --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"ADMIN_USER="* ]]
}

@test "rejects a private key pasted into ADMIN_SSH_PUBKEY" {
  set_cfg "ADMIN_USER=deploy" 'ADMIN_SSH_PUBKEY="-----BEGIN OPENSSH PRIVATE KEY-----"'
  run harden --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"ADMIN_SSH_PUBKEY="* ]]
}

@test "ADMIN_USER without a key fails when the user step runs" {
  set_cfg "ADMIN_USER=deploy"
  run harden --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"ADMIN_SSH_PUBKEY is required"* ]]
  run harden --check-config --only sysctl
  [ "$status" -eq 0 ]
}

@test "SSH_ALLOW_USERS must include ADMIN_USER" {
  set_cfg "ADMIN_USER=deploy" "ADMIN_SSH_PUBKEY=\"$KEY\"" 'SSH_ALLOW_USERS="ops"'
  run harden --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"would be locked out"* ]]
}

@test "panel port must differ from SSH port" {
  set_cfg "SSH_PORT=8443" "UFW_PANEL_PORT=8443"
  run harden --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"UFW_PANEL_PORT and SSH_PORT are both 8443"* ]]
}

@test "allow-list without a panel port only warns" {
  set_cfg 'UFW_PANEL_ALLOW="203.0.113.10"'
  run harden --check-config
  [ "$status" -eq 0 ]
  [[ "$output" == *"allow-list is ignored"* ]]
}

@test "unknown step is rejected before any step runs" {
  run harden --dry-run --only sysctl,firewall
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown step: firewall"* ]]
  [[ "$output" != *"== sysctl"* ]]
}

@test "invalid config stops a dry run before it prints any command" {
  set_cfg "SSH_PORT=abc"
  run harden --dry-run --only ssh
  [ "$status" -eq 1 ]
  [[ "$output" != *"[DRY-RUN]"* ]]
}

@test "--check-config does not need root" {
  [ "$(id -u)" -ne 0 ] || skip "running as root"
  run harden --check-config
  [ "$status" -eq 0 ]
  [[ "$output" != *"must be run as root"* ]]
}

@test "dry run of the sysctl step prints the file and changes nothing" {
  run harden --dry-run --only sysctl
  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN] write /etc/sysctl.d/99-hardening.conf"* ]]
  [[ "$output" == *"net.ipv4.tcp_syncookies = 1"* ]]
  [[ "$output" == *"[DRY-RUN] sysctl --system"* ]]
}

@test "dry run of the ssh step renders port and AllowUsers from config" {
  set_cfg "SSH_PORT=2222" 'SSH_ALLOW_USERS="deploy"'
  run harden --dry-run ssh
  [ "$status" -eq 0 ]
  [[ "$output" == *"| Port 2222"* ]]
  [[ "$output" == *"| AllowUsers deploy"* ]]
  [[ "$output" == *"| PermitRootLogin no"* ]]
}

@test "dry run of the ufw step uses one rule per allow-list entry" {
  set_cfg "UFW_PANEL_PORT=8443" 'UFW_PANEL_ALLOW="203.0.113.10 198.51.100.0/24"'
  run harden --dry-run ufw
  [ "$status" -eq 0 ]
  [[ "$output" == *"ufw allow from 203.0.113.10 to any port 8443 proto tcp"* ]]
  [[ "$output" == *"ufw allow from 198.51.100.0/24 to any port 8443 proto tcp"* ]]
  [[ "$output" != *"open to the whole internet"* ]]
}

@test "refuses a world-writable config file" {
  chmod 666 "$CFG"
  run harden --check-config
  [ "$status" -eq 1 ]
  [[ "$output" == *"writable by group or others"* ]]
}
