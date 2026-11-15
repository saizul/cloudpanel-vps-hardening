#!/usr/bin/env bats
# audit.sh: every check against a fake server (AUDIT_ROOT file tree + AUDIT_FIXTURES command
# outputs), so the suite needs no root, no Linux /proc and no installed services.

load test_helper

# Build a fully hardened fake server; tests then break one thing at a time.
good_server() {
  ROOT="$TMP/root"; FIX="$TMP/fixtures"
  export AUDIT_ROOT="$ROOT" AUDIT_FIXTURES="$FIX"
  mkdir -p "$FIX" "$ROOT/etc/apt/apt.conf.d" "$ROOT/var/run"

  cat >"$FIX/sshd-T" <<'OUT'
port 22
permitrootlogin no
passwordauthentication no
kbdinteractiveauthentication no
permitemptypasswords no
pubkeyauthentication yes
maxauthtries 3
x11forwarding no
OUT
  cat >"$FIX/ufw-status" <<'OUT'
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), disabled (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
22/tcp                     ALLOW IN    Anywhere
80/tcp                     ALLOW IN    Anywhere
443/tcp                    ALLOW IN    Anywhere
OUT
  printf 'Status for the jail: sshd\n|- Filter\n|  |- Currently banned:\t2\n' >"$FIX/fail2ban-sshd"
  printf '/swapfile file 2G 0B -2\n' >"$FIX/swapon"
  printf 'Timezone=UTC\nNTP=yes\nNTPSynchronized=yes\n' >"$FIX/timedatectl"

  local kv key
  while IFS= read -r kv; do
    key="${kv%%=*}"
    mkdir -p "$ROOT/proc/sys/$(dirname "$(printf '%s' "$key" | tr . /)")"
    printf '%s\n' "${kv#*=}" >"$ROOT/proc/sys/$(printf '%s' "$key" | tr . /)"
  done <<'EOF'
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.all.accept_source_route=0
net.ipv6.conf.all.accept_source_route=0
net.ipv4.icmp_echo_ignore_broadcasts=1
net.ipv4.tcp_syncookies=1
net.ipv4.conf.all.log_martians=1
kernel.kptr_restrict=2
kernel.dmesg_restrict=1
EOF

  printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
    >"$ROOT/etc/apt/apt.conf.d/20auto-upgrades"
  printf 'root:x:0:0:root:/root:/bin/bash\ndeploy:x:1000:1000::/home/deploy:/bin/bash\n' >"$ROOT/etc/passwd"
  printf 'root:*:19000:0:99999:7:::\ndeploy:!:19000:0:99999:7:::\n' >"$ROOT/etc/shadow"
}

audit() { "$REPO/audit.sh" --config "$CFG" "$@"; }

@test "a fully hardened server passes every check and exits 0" {
  good_server
  run audit
  [ "$status" -eq 0 ]
  [[ "$output" != *"FAIL "* ]]
  [[ "$output" != *"WARN  "* ]]
  [[ "$output" == *"PASS  fail2ban  sshd jail running, 2 IP(s) currently banned"* ]]
  [[ "$output" == *"SKIP  redis     not installed"* ]]
  [[ "$output" == *"0 fail"* ]]
}

@test "--check-config rejects an unknown check and a bad SSH_PORT" {
  set_cfg "SSH_PORT=99999"
  run audit --check-config --only ssh,firewall
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown check: firewall"* ]]
  [[ "$output" == *"SSH_PORT='99999' is invalid"* ]]
  [[ "$output" == *"2 config error(s)"* ]]
}

@test "root login and password authentication left on are failures" {
  good_server
  sed -i.bak 's/^permitrootlogin no/permitrootlogin yes/; s/^passwordauthentication no/passwordauthentication yes/' "$FIX/sshd-T"
  run audit --only ssh
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  ssh       permitrootlogin is 'yes', expected 'no'"* ]]
  [[ "$output" == *"FAIL  ssh       passwordauthentication is 'yes'"* ]]
  [[ "$output" == *"2 fail"* ]]
}

@test "sshd keywords are matched case-insensitively and old OpenSSH names are understood" {
  good_server
  sed -i.bak '/^kbdinteractiveauthentication/d; s/^permitrootlogin no/PermitRootLogin No/' "$FIX/sshd-T"
  printf 'challengeresponseauthentication no\n' >>"$FIX/sshd-T"
  run audit --only ssh
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS  ssh       kbdinteractiveauthentication no"* ]]
}

@test "an sshd port that differs from SSH_PORT is a failure" {
  good_server
  set_cfg "SSH_PORT=2222"
  run audit --only ssh
  [ "$status" -eq 1 ]
  [[ "$output" == *"sshd ports are '22', SSH_PORT is 2222"* ]]
}

@test "an sshd config that does not parse is a failure" {
  good_server
  : >"$FIX/sshd-T"
  run audit --only ssh
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not parse"* ]]
}

@test "AllowUsers must contain every SSH_ALLOW_USERS entry" {
  good_server
  set_cfg 'SSH_ALLOW_USERS="deploy ops"'
  printf 'allowusers deploy\n' >>"$FIX/sshd-T"
  run audit --only ssh
  [ "$status" -eq 1 ]
  [[ "$output" == *"allowusers is missing: ops"* ]]
}

@test "weak but non-critical sshd settings are warnings; --strict turns them into exit 1" {
  good_server
  sed -i.bak 's/^maxauthtries 3/maxauthtries 6/; s/^x11forwarding no/x11forwarding yes/' "$FIX/sshd-T"
  run audit --only ssh
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  ssh       maxauthtries is '6'"* ]]
  [[ "$output" == *"WARN  ssh       x11forwarding is 'yes'"* ]]
  run audit --only ssh --strict
  [ "$status" -eq 1 ]
}

@test "an inactive firewall is a failure" {
  good_server
  printf 'Status: inactive\n' >"$FIX/ufw-status"
  run audit --only ufw
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  ufw       firewall is not active"* ]]
}

@test "a firewall without a rule for the SSH port is a failure" {
  good_server
  set_cfg "SSH_PORT=2222"
  run audit --only ufw
  [ "$status" -eq 1 ]
  [[ "$output" == *"no ALLOW rule for SSH port 2222"* ]]
}

@test "panel port open to Anywhere fails when an allow-list is configured" {
  good_server
  set_cfg "UFW_PANEL_PORT=8443" 'UFW_PANEL_ALLOW="203.0.113.10"'
  printf '8443/tcp                   ALLOW IN    Anywhere\n' >>"$FIX/ufw-status"
  run audit --only ufw
  [ "$status" -eq 1 ]
  [[ "$output" == *"open to Anywhere although UFW_PANEL_ALLOW is set"* ]]
}

@test "panel port restricted to the allow-list passes" {
  good_server
  set_cfg "UFW_PANEL_PORT=8443" 'UFW_PANEL_ALLOW="203.0.113.10"'
  printf '8443/tcp                   ALLOW IN    203.0.113.10\n' >>"$FIX/ufw-status"
  run audit --only ufw
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS  ufw       panel port 8443 restricted to an allow-list"* ]]
}

@test "a stopped fail2ban sshd jail is a failure" {
  good_server
  rm "$FIX/fail2ban-sshd"
  run audit --only fail2ban
  [ "$status" -eq 1 ]
  [[ "$output" == *"sshd jail is not running"* ]]
}

@test "a sysctl value that drifted is reported with the key and both values" {
  good_server
  printf '0\n' >"$ROOT/proc/sys/net/ipv4/tcp_syncookies"
  run audit --only sysctl
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  sysctl    net.ipv4.tcp_syncookies = 0, expected 1"* ]]
}

@test "missing unattended upgrades fail and a pending reboot warns" {
  good_server
  rm "$ROOT/etc/apt/apt.conf.d/20auto-upgrades"
  : >"$ROOT/var/run/reboot-required"
  run audit --only updates
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  updates   unattended upgrades are not enabled"* ]]
  [[ "$output" == *"WARN  updates   a reboot is required"* ]]
}

@test "no swap, no NTP sync and a different timezone are warnings only" {
  good_server
  : >"$FIX/swapon"
  printf 'Timezone=Asia/Dhaka\nNTPSynchronized=no\n' >"$FIX/timedatectl"
  run audit --only swap,time
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  swap      no active swap"* ]]
  [[ "$output" == *"WARN  time      clock is not NTP synchronised"* ]]
  [[ "$output" == *"timezone is 'Asia/Dhaka', TIMEZONE is 'UTC'"* ]]
}

@test "extra UID 0 accounts, empty passwords and a missing ADMIN_USER are failures" {
  good_server
  set_cfg "ADMIN_USER=ops"
  printf 'toor:x:0:0::/root:/bin/sh\n' >>"$ROOT/etc/passwd"
  printf 'toor::19000:0:99999:7:::\n' >>"$ROOT/etc/shadow"
  run audit --only accounts
  [ "$status" -eq 1 ]
  [[ "$output" == *"accounts other than root with UID 0: toor"* ]]
  [[ "$output" == *"accounts with an empty password: toor"* ]]
  [[ "$output" == *"ADMIN_USER ops does not exist"* ]]
}

@test "redis bound to loopback passes; the last bind line wins" {
  good_server
  mkdir -p "$ROOT/etc/redis"
  printf 'bind 0.0.0.0\nprotected-mode yes\nbind 127.0.0.1 -::1\n' >"$ROOT/etc/redis/redis.conf"
  run audit --only redis
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS  redis     bound to loopback only"* ]]
}

@test "redis on a public interface or without bind is a failure" {
  good_server
  mkdir -p "$ROOT/etc/redis"
  printf 'bind 127.0.0.1 10.0.0.5\n' >"$ROOT/etc/redis/redis.conf"
  run audit --only redis
  [ "$status" -eq 1 ]
  [[ "$output" == *"bound to non-loopback address(es): 10.0.0.5"* ]]
  printf 'port 6379\nprotected-mode no\n' >"$ROOT/etc/redis/redis.conf"
  run audit --only redis
  [ "$status" -eq 1 ]
  [[ "$output" == *"no bind directive"* ]]
  [[ "$output" == *"WARN  redis     protected-mode is off"* ]]
}

@test "--quiet prints only problems and stays silent on a clean server" {
  good_server
  run audit --quiet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  printf 'Status: inactive\n' >"$FIX/ufw-status"
  run audit --quiet
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  ufw       firewall is not active"* ]]
  [[ "$output" != *"PASS"* ]]
}

@test "the audit never writes to the server tree" {
  good_server
  before="$(find "$ROOT" "$FIX" -type f -exec cksum {} + | sort)"
  run audit
  after="$(find "$ROOT" "$FIX" -type f -exec cksum {} + | sort)"
  [ "$before" = "$after" ]
}
