# SSH Password Login Enabler

A production-focused Bash script to enable SSH password authentication for a chosen user (including `root`) on common Linux server images.

Script file: `enable_ssh_password_login.sh`

## What it does

- Prompts for target username (default: `root`)
- Prompts for and sets a new password securely
- Optionally creates the user if it does not exist
- Updates SSH server config with an idempotent managed block
- Enables password-related SSH auth directives
- Enables `PermitRootLogin yes` when target user is `root`
- Tries to neutralize cloud-init password-auth disablement (`ssh_pwauth`)
- Validates SSH config before restart
- Restarts `sshd`/`ssh` service
- Creates timestamped backups before changing files

## Supported targets

Designed for most Debian/Ubuntu, RHEL/CentOS/Rocky/Alma, and many cloud images.

Primary config paths covered:

- `/etc/ssh/sshd_config`
- `/etc/sshd_config`
- `/etc/cloud/cloud.cfg`
- `/etc/cloud/cloud.cfg.d/*.cfg`

## Usage

1. Copy script to your server (while logged in with key-based SSH):

```bash
scp enable_ssh_password_login.sh root@SERVER_IP:/root/
```

2. Run it as root:

```bash
sudo bash /root/enable_ssh_password_login.sh
```

3. Follow prompts:

- username (default `root`)
- password + confirmation

4. Test in a second terminal session before closing the current one:

```bash
ssh root@SERVER_IP
```

## Important security warning

Enabling SSH password login (especially for `root`) increases brute-force risk.

Strongly recommended after enabling:

- Keep a strong password
- Change SSH port if needed
- Enable firewall rules (`ufw`/`firewalld`/security groups)
- Install fail2ban
- Restrict source IPs where possible

## Rollback

The script automatically creates backup files like:

- `/etc/ssh/sshd_config.bak.YYYYmmdd-HHMMSS`
- `/etc/cloud/cloud.cfg.bak.YYYYmmdd-HHMMSS`

To rollback, restore backup and restart SSH:

```bash
sudo cp /etc/ssh/sshd_config.bak.YYYYmmdd-HHMMSS /etc/ssh/sshd_config
sudo systemctl restart sshd || sudo systemctl restart ssh
```

## Notes

- The script is idempotent for its managed block and can be re-run.
- It does not remove your existing key-based login.
- Always keep your current SSH session open while testing new login behavior.
