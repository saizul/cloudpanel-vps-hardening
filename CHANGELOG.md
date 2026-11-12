# Changelog

All notable changes to this project are documented here. Format based on Keep a Changelog.

## [Unreleased]

### Added
- Config validation for `harden.sh`, `backup.sh` and `redis-setup.sh`: every setting is checked before any change (ports, user names, SSH public key, IP/CIDR allow-list, fail2ban times, swap size, timezone, backup paths, rclone remote, Redis memory/policy/password), all problems are reported at once, and nothing is touched on error. New `--check-config` option validates and exits without needing root.
- `harden.sh` rejects unknown steps before running any step, and refuses `SSH_ALLOW_USERS` that would lock out `ADMIN_USER` or a panel port equal to the SSH port.
- Every script refuses to source a `config.env` that is writable by group or others, since it runs as root.
- `ssl-expiry-check.sh` validates `SSL_TIMEOUT`.
- bats test suite (`tests/`, 65 tests) for the `lib/common.sh` helpers and validators and for each script's options and dry runs; `Makefile` with `lint`/`test`/`check`; CI runs the suite and full-severity ShellCheck on scripts and tests; `.gitignore` for `config.env` and local tool installs.
- `ssl-expiry-check.sh`: reads the certificate each listed host serves and warns below `SSL_WARN_DAYS`; supports `HOST[:PORT]`, `--days`, `--dry-run`, and exits 1 on problems.

## [0.1.0] - 2026-11-07

### Added
- `harden.sh` with modular steps: updates (unattended-upgrades), user, ssh, ufw, fail2ban, sysctl, swap, time.
- `php-update-check.sh`: lists installed php*-fpm versions, pending PHP package updates, EOL warnings.
- `backup.sh`: per-database dumps, per-site tarballs, retention, optional rclone upload.
- `redis-setup.sh`: localhost-only Redis with memory cap and optional password.
- `lib/common.sh` shared helpers; `--dry-run` on every script; `config.env.example`.
