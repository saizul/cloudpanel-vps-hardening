# Changelog

All notable changes to this project are documented here. Format based on Keep a Changelog.

## [0.1.0] - 2026-11-07

### Added
- `harden.sh` with modular steps: updates (unattended-upgrades), user, ssh, ufw, fail2ban, sysctl, swap, time.
- `php-update-check.sh`: lists installed php*-fpm versions, pending PHP package updates, EOL warnings.
- `backup.sh`: per-database dumps, per-site tarballs, retention, optional rclone upload.
- `redis-setup.sh`: localhost-only Redis with memory cap and optional password.
- `lib/common.sh` shared helpers; `--dry-run` on every script; `config.env.example`.
