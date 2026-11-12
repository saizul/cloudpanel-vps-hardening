# cloudpanel-vps-hardening

[![CI](https://github.com/saizul/cloudpanel-vps-hardening/actions/workflows/ci.yml/badge.svg)](https://github.com/saizul/cloudpanel-vps-hardening/actions/workflows/ci.yml) ![Bash](https://img.shields.io/badge/bash-5-4EAA25?logo=gnubash&logoColor=white) ![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04-E95420?logo=ubuntu&logoColor=white)

Small, readable Bash scripts to harden and maintain an Ubuntu 22.04 / 24.04 VPS. They work on a plain server and on one running [CloudPanel](https://www.cloudpanel.io/) (which adds a panel on port 8443 and manages Nginx, PHP-FPM and MySQL/MariaDB for you).

By [Saizul Amin](https://saizul.com). MIT licensed.

Every script: `set -euo pipefail`, requires root (except `--dry-run`), supports `--dry-run` (prints commands only), checks state before changing it so re-runs are safe, logs with timestamps, and reads settings from `config.env`.

## Quick start

```bash
git clone <this repo> && cd cloudpanel-vps-hardening
cp config.env.example config.env && chmod 600 config.env && nano config.env
./harden.sh --check-config          # validate settings (no root needed)
sudo ./harden.sh --dry-run          # read the plan first
sudo ./harden.sh                    # apply all steps
sudo ./harden.sh --only ufw,fail2ban
```

## Read this before you run it

- Keep a second SSH session open while running the `ssh` and `ufw` steps. Only close it after a fresh login in a new terminal works.
- Disabling root and password login locks you out if no non-root key exists. The script refuses to continue without one; create it with the `user` step (`ADMIN_USER` + `ADMIN_SSH_PUBKEY`).
- If you change `SSH_PORT`, also allow it in your hosting provider's firewall. On Ubuntu 24.04 SSH is socket-activated, so the port comes from `ssh.socket`; the script warns and prints the fix.
- With CloudPanel, never close the panel port you use. Set `UFW_PANEL_PORT=8443` and `UFW_PANEL_ALLOW` to your IPs. If the allow-list is empty the port is opened to everyone (a warning is shown). CloudPanel may also manage its own firewall rules in the UI; check for conflicts.
- Test on a throwaway VPS or snapshot first. No warranty, see LICENSE.

## Config validation

`harden.sh`, `backup.sh` and `redis-setup.sh` validate `config.env` and the step list before they change anything, report every problem at once, and exit `1` without touching the server. Run `--check-config` to do only that (no root needed), for example after editing the file or in CI:

```bash
./harden.sh --check-config && ./backup.sh --check-config && ./redis-setup.sh --check-config
```

What is checked:

| Setting | Rule |
|---------|------|
| `ADMIN_USER` | lowercase account name (`[a-z_][a-z0-9_-]*`, max 32); prevents a broken `/etc/sudoers.d` drop-in |
| `ADMIN_SSH_PUBKEY` | one public key line (`ssh-ed25519`, `ssh-rsa`, `ecdsa-*`, `sk-*`); rejects pasted private keys and multi-line values; required when `ADMIN_USER` is set and the `user` step runs |
| `SSH_PORT`, `UFW_PANEL_PORT` | TCP port 1-65535; the two must differ |
| `SSH_ALLOW_USERS` | `USER` or `USER@HOST` entries; must include `ADMIN_USER` when both are set (otherwise that account is locked out) |
| `UFW_PANEL_ALLOW` | IPv4/IPv6 addresses or CIDRs |
| `F2B_MAXRETRY`, `F2B_FINDTIME`, `F2B_BANTIME` | whole number; fail2ban times such as `600`, `10m`, `1h30m`, `-1` |
| `SWAP_SIZE`, `TIMEZONE` | `2G`/`512M` style size; a zone that exists in `/usr/share/zoneinfo` |
| `BACKUP_DIR`, `SITES_DIR` | absolute, not `/`, no `..` (retention runs `rm -rf` under `BACKUP_DIR`) |
| `BACKUP_RETENTION_DAYS`, `RCLONE_REMOTE` | whole number; `REMOTE:PATH` or an absolute path |
| `REDIS_MAXMEMORY`, `REDIS_POLICY`, `REDIS_PASSWORD` | `256mb` style size; a valid `maxmemory-policy`; one token without spaces |

Unknown `harden.sh` steps are rejected up front too, so `--only sysctl,firewall` no longer runs `sysctl` before failing. Because `config.env` is sourced as root, every script refuses to load it when it is writable by group or others (`chmod 600 config.env`).

## harden.sh steps

| Step | What it does |
|------|--------------|
| `updates` | `apt update && upgrade`, installs `unattended-upgrades`, enables daily security updates |
| `user` | Creates `ADMIN_USER` (no password), adds to `sudo`, installs your public key, writes a sudoers drop-in |
| `ssh` | Writes `/etc/ssh/sshd_config.d/00-hardening.conf`: key-only, `PermitRootLogin no`, optional `Port`/`AllowUsers`, `MaxAuthTries 3`; validates with `sshd -t` before reload |
| `ufw` | Default deny incoming; allows SSH port, 80, 443; optional panel port with IP allow-list |
| `fail2ban` | Installs fail2ban and enables an `sshd` jail (retries/ban time configurable) |
| `sysctl` | `/etc/sysctl.d/99-hardening.conf`: rp_filter, no redirects/source routing, SYN cookies, martian logging, kptr/dmesg restrictions |
| `swap` | Creates `SWAP_SIZE` swap file only if no swap is active; swappiness 10 |
| `time` | Sets `TIMEZONE`, enables NTP via `timedatectl` |

Run a subset: `./harden.sh --only updates,swap` or `./harden.sh ssh ufw`.

## php-update-check.sh

Lists `php*-fpm` services with state, support end dates (table inside the script; verify against php.net), warns for EOL versions, and shows pending `php*` package upgrades, flagging security ones. Read-only apart from `apt-get update`.

## ssl-expiry-check.sh

Connects to each host with `openssl s_client` (SNI aware) and reads the certificate it really serves, so a renewed certificate that Nginx never reloaded is caught too. Warns when fewer than `SSL_WARN_DAYS` (default 21) remain, errors on expired certificates and on hosts it cannot read, and exits `1` if anything needs attention (`0` otherwise), which suits cron and monitoring. It needs no root and changes nothing.

```bash
./ssl-expiry-check.sh example.com www.example.com mail.example.com:465   # ad hoc; HOST[:PORT], default port 443
./ssl-expiry-check.sh --days 30                                          # SSL_DOMAINS from config.env
./ssl-expiry-check.sh --dry-run example.com                              # print the openssl commands only
```

Settings in `config.env`: `SSL_DOMAINS` (space separated), `SSL_WARN_DAYS`, `SSL_TIMEOUT` (seconds per host, uses `timeout` when installed). With `--quiet` only warnings and errors are printed, so a cron job mails you (or a log shipper alerts) only when something needs attention:

```
5 8 * * * /opt/cloudpanel-vps-hardening/ssl-expiry-check.sh --quiet --config /opt/cloudpanel-vps-hardening/config.env
```

## backup.sh

Creates `BACKUP_DIR/<timestamp>/` containing `db-<name>.sql.gz` per database (`--single-transaction`, routines, events) and `files-<dir>.tar.gz` per directory under `SITES_DIR` (CloudPanel keeps sites under `/home/<site-user>`). Deletes sets older than `BACKUP_RETENTION_DAYS`, then optionally runs `rclone copy` to `RCLONE_REMOTE`. Put DB credentials in `/root/.my.cnf` (mode 600). Options: `--skip-db`, `--skip-files`. Test a restore regularly; a backup you have not restored is a hope, not a backup. Example cron:

```
17 3 * * * /opt/cloudpanel-vps-hardening/backup.sh --config /opt/cloudpanel-vps-hardening/config.env >> /var/log/vps-backup.log 2>&1
```

## redis-setup.sh

Installs `redis-server`, binds it to localhost, sets `maxmemory` and eviction policy, optional `requirepass`, using an idempotent managed block in `/etc/redis/redis.conf` (original saved to `.orig`). Pair with an object-cache plugin for WordPress.

## Development

Tests use [bats-core](https://github.com/bats-core/bats-core) and never need root or change the system: they call the `lib/common.sh` helpers directly and run the scripts with `--check-config` / `--dry-run` against a temporary config. They also run on macOS's stock Bash 3.2.

```bash
make check                        # = make lint test
make lint                         # bash -n + shellcheck on scripts and tests
make test                         # bats tests
bats tests/harden.bats            # one file
```

Install the tools with `apt-get install bats shellcheck` (Ubuntu), `brew install bats-core shellcheck` (macOS), or without a package manager: `npm install bats` and `pip install shellcheck-py` (both ignored by `.gitignore`), then `make check BATS=node_modules/.bin/bats`. CI runs the same lint and test steps on every push and pull request.

## License

MIT, see [LICENSE](LICENSE).
