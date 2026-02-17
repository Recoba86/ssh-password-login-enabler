# SSH Password Login Enabler

One-click + interactive setup to enable SSH password authentication for a chosen Linux user (including `root`).

## One-Click usage (recommended)

Paste this on the target server (while logged in with SSH key):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Recoba86/ssh-password-login-enabler/main/one_click_setup.sh)"
```

What happens automatically:

- Downloads the main setup script from GitHub
- Asks for username (default: `root`)
- Asks for password + confirmation
- Applies SSH/cloud-init changes
- Validates `sshd` config
- Restarts SSH service
- Runs post-activation checks
- Asks whether to install `fail2ban` (optional, default is `No`)

## Repository files

- `one_click_setup.sh`: bootstrap downloader/runner
- `enable_ssh_password_login.sh`: main configurator script

## What the main script changes

- Prompts for target username and password
- Creates user optionally if missing
- Enables password auth directives:
  - `PasswordAuthentication yes`
  - `KbdInteractiveAuthentication yes`
  - `ChallengeResponseAuthentication yes`
  - `UsePAM yes`
- Enables `PermitRootLogin yes` when target user is `root`
- Adds `Match User <user>` block for explicit password auth
- Updates cloud-init entries when present:
  - `ssh_pwauth: true`
  - `disable_root: false` (for root target)
- Creates timestamped backups before changes
- Does not enable or modify firewall rules

## Post-activation checks

After restart, script checks:

- Effective `sshd` settings (`sshd -T -C ...`)
- Password auth enabled
- Root login enabled (if target is root)
- Active SSH password login to `127.0.0.1` if `sshpass` is installed

If `sshpass` is not installed, config checks still run and the active login test is skipped.

## Manual usage (without one-click)

```bash
sudo bash enable_ssh_password_login.sh
```

## Security warning

Enabling SSH password login, especially for `root`, increases brute-force risk.

Recommended hardening:

- Strong password
- Optional `fail2ban` (installer now asks: `[y/N]`, default `No`)
- Keep key-based SSH enabled as backup

## Rollback

Backups are created automatically, for example:

- `/etc/ssh/sshd_config.bak.YYYYmmdd-HHMMSS`
- `/etc/cloud/cloud.cfg.bak.YYYYmmdd-HHMMSS`

Rollback example:

```bash
sudo cp /etc/ssh/sshd_config.bak.YYYYmmdd-HHMMSS /etc/ssh/sshd_config
sudo systemctl restart sshd || sudo systemctl restart ssh
```
