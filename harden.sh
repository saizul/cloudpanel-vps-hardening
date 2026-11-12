#!/usr/bin/env bash
# harden.sh - modular hardening for Ubuntu 22.04/24.04 (with or without CloudPanel).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"

ALL_STEPS="updates user ssh ufw fail2ban sysctl swap time"
STEPS=""
CHECK_ONLY=0

usage() {
  cat <<USAGE
Usage: sudo $0 [options] [step ...]

Steps: $ALL_STEPS   (default: all except 'user' unless ADMIN_USER is set)
Options:
  --config FILE   config file (default: ./config.env if present)
  --only STEPS    comma-separated steps to run
  --dry-run       print commands, change nothing
  --check-config  validate config.env and the step list, then exit (no root needed)
  -h, --help      show help

IMPORTANT: keep a second SSH session open while running the 'ssh' and 'ufw' steps.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --config) CONFIG_FILE="${2:?--config needs a file}"; shift 2 ;;
    --only)   STEPS="${2//,/ }"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --check-config) CHECK_ONLY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) STEPS="$STEPS $1"; shift ;;
  esac
done

load_config "$HERE"
: "${ADMIN_USER:=}" "${ADMIN_SSH_PUBKEY:=}" "${SSH_PORT:=22}" "${SSH_ALLOW_USERS:=}"
: "${UFW_PANEL_PORT:=}" "${UFW_PANEL_ALLOW:=}" "${F2B_MAXRETRY:=5}" "${F2B_FINDTIME:=10m}"
: "${F2B_BANTIME:=1h}" "${SWAP_SIZE:=2G}" "${TIMEZONE:=UTC}"

if [ -z "${STEPS// /}" ]; then
  STEPS="$ALL_STEPS"
fi

# Validate everything before the first change: a typo must not leave the server half hardened
# (e.g. ufw enabled but the SSH port wrong) or write a sudoers/sshd file that breaks login.
validate_config() {
  local s
  for s in $STEPS; do
    case " $ALL_STEPS " in *" $s "*) ;; *) config_error "unknown step: $s (valid: $ALL_STEPS)" ;; esac
  done
  check_var ADMIN_USER is_unix_user "a lowercase account name, e.g. deploy" optional
  check_var ADMIN_SSH_PUBKEY is_ssh_pubkey "one public key line, e.g. 'ssh-ed25519 AAAA... you@laptop'" optional
  if [ -n "$ADMIN_USER" ] && [ -z "$ADMIN_SSH_PUBKEY" ]; then
    case " $STEPS " in *" user "*) config_error "ADMIN_SSH_PUBKEY is required when ADMIN_USER is set (key-only login)" ;; esac
  fi
  check_var SSH_PORT is_port "a TCP port 1-65535"
  check_list SSH_ALLOW_USERS is_ssh_allow_entry "USER or USER@HOST"
  if [ -n "$ADMIN_USER" ] && [ -n "$SSH_ALLOW_USERS" ]; then
    case " $SSH_ALLOW_USERS " in
      *" $ADMIN_USER "*|*" $ADMIN_USER@"*) ;;
      *) config_error "SSH_ALLOW_USERS does not include ADMIN_USER '$ADMIN_USER'; that account would be locked out" ;;
    esac
  fi
  check_var UFW_PANEL_PORT is_port "a TCP port 1-65535, e.g. 8443" optional
  if [ -n "$UFW_PANEL_PORT" ] && [ "$UFW_PANEL_PORT" = "$SSH_PORT" ]; then
    config_error "UFW_PANEL_PORT and SSH_PORT are both $SSH_PORT"
  fi
  check_list UFW_PANEL_ALLOW is_ip_or_cidr "IPv4/IPv6 addresses or CIDRs, e.g. 203.0.113.10 198.51.100.0/24"
  if [ -n "$UFW_PANEL_ALLOW" ] && [ -z "$UFW_PANEL_PORT" ]; then
    warn "UFW_PANEL_ALLOW is set but UFW_PANEL_PORT is empty; the allow-list is ignored"
  fi
  check_var F2B_MAXRETRY is_uint "a whole number"
  check_var F2B_FINDTIME is_f2b_time "a fail2ban time such as 600, 10m, 1h"
  check_var F2B_BANTIME is_f2b_time "a fail2ban time such as 1h, 1d, or -1 for permanent"
  check_var SWAP_SIZE is_size "a size such as 2G or 512M"
  check_var TIMEZONE is_timezone "a zone from 'timedatectl list-timezones', e.g. UTC or Europe/London"
  finish_config_check
}
validate_config
[ "$CHECK_ONLY" -eq 0 ] || exit 0

require_root
check_ubuntu

step_updates() {
  log "== updates: apt upgrade + unattended-upgrades"
  run apt-get update
  run env DEBIAN_FRONTEND=noninteractive apt-get -y upgrade
  pkg_installed unattended-upgrades || apt_install unattended-upgrades
  write_file /etc/apt/apt.conf.d/20auto-upgrades 0644 <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
}

step_user() {
  if [ -z "$ADMIN_USER" ]; then
    log "== user: ADMIN_USER not set, skipping"; return 0
  fi
  log "== user: $ADMIN_USER"
  [ -n "$ADMIN_SSH_PUBKEY" ] || die "ADMIN_SSH_PUBKEY is required to create $ADMIN_USER (key-only login)"
  if id "$ADMIN_USER" >/dev/null 2>&1; then
    log "user exists: $ADMIN_USER"
  else
    run adduser --disabled-password --gecos "" "$ADMIN_USER"
  fi
  run usermod -aG sudo "$ADMIN_USER"
  local home ak
  home="/home/$ADMIN_USER"; ak="$home/.ssh/authorized_keys"
  run install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home/.ssh"
  if [ -f "$ak" ] && grep -qxF "$ADMIN_SSH_PUBKEY" "$ak"; then
    log "public key already present"
  elif [ "$DRY_RUN" -eq 1 ]; then
    printf '[DRY-RUN] append public key to %s\n' "$ak"
  else
    printf '%s\n' "$ADMIN_SSH_PUBKEY" >>"$ak"
    chown "$ADMIN_USER:$ADMIN_USER" "$ak"; chmod 600 "$ak"
  fi
  # Passwordless sudo is convenient with key-only accounts; remove the file to require a password.
  write_file "/etc/sudoers.d/90-$ADMIN_USER" 0440 <<CONF
$ADMIN_USER ALL=(ALL) NOPASSWD:ALL
CONF
}

step_ssh() {
  log "== ssh: key-only, no root login, port $SSH_PORT"
  warn "KEEP A SECOND SSH SESSION OPEN and confirm key login works before closing this one"
  if [ -n "$ADMIN_USER" ] && [ -f "/home/$ADMIN_USER/.ssh/authorized_keys" ]; then
    :
  elif compgen -G "/home/*/.ssh/authorized_keys" >/dev/null; then
    warn "ADMIN_USER not set; confirm the account that owns a /home/*/.ssh/authorized_keys can sudo"
  else
    [ "$DRY_RUN" -eq 1 ] || die "no non-root authorized_keys found; with root login disabled you would be locked out. Set ADMIN_USER + ADMIN_SSH_PUBKEY and run the 'user' step first"
    warn "no non-root authorized_keys found; a real run would refuse here"
  fi
  local allow=""
  [ -z "$SSH_ALLOW_USERS" ] || allow="AllowUsers $SSH_ALLOW_USERS"
  run install -d -m 755 /etc/ssh/sshd_config.d
  # 00- prefix: sshd uses the first value it sees, so this wins over later drop-ins.
  write_file /etc/ssh/sshd_config.d/00-hardening.conf 0644 <<CONF
# Managed by harden.sh
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
X11Forwarding no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
$allow
CONF
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '[DRY-RUN] sshd -t && reload ssh service\n'
  else
    sshd -t || die "sshd config test failed; not reloading"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd
    log "sshd reloaded. Test a NEW session now before closing this one."
  fi
  if [ "$SSH_PORT" != "22" ] && systemctl is-active --quiet ssh.socket 2>/dev/null; then
    warn "ssh.socket is active (Ubuntu 24.04): the port is set by the socket, not sshd_config. Run: systemctl disable --now ssh.socket && systemctl enable --now ssh"
  fi
  if [ "$SSH_PORT" != "22" ]; then
    warn "SSH port is $SSH_PORT: ensure UFW and any provider firewall allow it (ufw step does so)"
  fi
}

step_ufw() {
  log "== ufw: ssh/http/https${UFW_PANEL_PORT:+ + panel $UFW_PANEL_PORT}"
  pkg_installed ufw || apt_install ufw
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow "${SSH_PORT}/tcp" comment 'SSH'
  [ "$SSH_PORT" = "22" ] || warn "port 22 is NOT opened; old sessions on 22 will not reconnect"
  run ufw allow 80/tcp comment 'HTTP'
  run ufw allow 443/tcp comment 'HTTPS'
  if [ -n "$UFW_PANEL_PORT" ]; then
    if [ -n "$UFW_PANEL_ALLOW" ]; then
      local src
      for src in $UFW_PANEL_ALLOW; do
        run ufw allow from "$src" to any port "$UFW_PANEL_PORT" proto tcp comment 'panel allow-list'
      done
    else
      warn "UFW_PANEL_ALLOW empty: panel port $UFW_PANEL_PORT will be open to the whole internet"
      run ufw allow "${UFW_PANEL_PORT}/tcp" comment 'panel'
    fi
  fi
  if ufw status 2>/dev/null | grep -q '^Status: active'; then
    log "ufw already active"
  else
    run ufw --force enable
  fi
}

step_fail2ban() {
  log "== fail2ban: sshd jail"
  pkg_installed fail2ban || apt_install fail2ban
  write_file /etc/fail2ban/jail.d/sshd-hardening.local 0644 <<CONF
[DEFAULT]
backend = systemd

[sshd]
enabled  = true
port     = $SSH_PORT
maxretry = $F2B_MAXRETRY
findtime = $F2B_FINDTIME
bantime  = $F2B_BANTIME
CONF
  run systemctl enable fail2ban
  run systemctl restart fail2ban
}

step_sysctl() {
  log "== sysctl: network hardening"
  write_file /etc/sysctl.d/99-hardening.conf 0644 <<'CONF'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.log_martians = 1
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
CONF
  run sysctl --system
}

step_swap() {
  log "== swap: $SWAP_SIZE if none exists"
  if [ "$DRY_RUN" -eq 0 ] && [ -n "$(swapon --show --noheadings 2>/dev/null)" ]; then
    log "swap already active, skipping"; return 0
  fi
  if [ -e /swapfile ] && [ "$DRY_RUN" -eq 0 ]; then
    warn "/swapfile exists but is not active; not touching it"; return 0
  fi
  run fallocate -l "$SWAP_SIZE" /swapfile
  run chmod 600 /swapfile
  run mkswap /swapfile
  run swapon /swapfile
  if ! grep -qs '^/swapfile ' /etc/fstab; then
    if [ "$DRY_RUN" -eq 1 ]; then
      printf '[DRY-RUN] append "/swapfile none swap sw 0 0" to /etc/fstab\n'
    else
      echo '/swapfile none swap sw 0 0' >>/etc/fstab
    fi
  fi
  write_file /etc/sysctl.d/99-swappiness.conf 0644 <<'CONF'
vm.swappiness = 10
CONF
  run sysctl -p /etc/sysctl.d/99-swappiness.conf
}

step_time() {
  log "== time: timezone $TIMEZONE + NTP"
  run timedatectl set-timezone "$TIMEZONE"
  run timedatectl set-ntp true
}

for s in $STEPS; do
  case "$s" in
    updates|user|ssh|ufw|fail2ban|sysctl|swap|time) "step_$s" ;;
    *) die "unknown step: $s (valid: $ALL_STEPS)" ;;  # unreachable after validate_config
  esac
done
log "done."
