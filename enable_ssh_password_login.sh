#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
MANAGED_BEGIN="# BEGIN CODEX SSH PASSWORD LOGIN"
MANAGED_END="# END CODEX SSH PASSWORD LOGIN"
TARGET_USER=""
TARGET_PASS=""

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$SCRIPT_NAME" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script as root (sudo)."
  fi
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

prompt_yes_no_default_no() {
  local prompt="$1"
  local ans
  read -r -p "$prompt [y/N]: " ans
  case "${ans:-N}" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

prompt_oracle_firewall_cleanup() {
  if prompt_yes_no_default_no "Is this server on Oracle Cloud and do you want to remove local iptables firewall rules?"; then
    return 0
  fi
  return 1
}

pick_sshd_config() {
  if [[ -f /etc/ssh/sshd_config ]]; then
    echo "/etc/ssh/sshd_config"
    return 0
  fi
  if [[ -f /etc/sshd_config ]]; then
    echo "/etc/sshd_config"
    return 0
  fi
  die "Cannot find sshd config (/etc/ssh/sshd_config or /etc/sshd_config)."
}

pick_sshd_bin() {
  if command_exists sshd; then
    command -v sshd
    return 0
  fi
  if [[ -x /usr/sbin/sshd ]]; then
    echo "/usr/sbin/sshd"
    return 0
  fi
  die "Cannot find sshd binary."
}

backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local b="${f}.bak.${TIMESTAMP}"
    cp -a "$f" "$b"
    log "Backup created: $b"
  fi
}

prompt_username() {
  read -r -p "Target username for SSH password login [root]: " TARGET_USER
  TARGET_USER="${TARGET_USER:-root}"
  if [[ -z "$TARGET_USER" ]]; then
    die "Username cannot be empty."
  fi
}

validate_username() {
  local user="$1"
  if [[ ! "$user" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    die "Username contains unsupported characters. Allowed: letters, numbers, dot, underscore, dash."
  fi
}

ensure_user_exists() {
  local user="$1"

  if id "$user" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$user" == "root" ]]; then
    die "User 'root' does not exist on this system."
  fi

  warn "User '$user' does not exist."
  read -r -p "Create this user now? [y/N]: " create_ans
  case "${create_ans:-N}" in
    y|Y|yes|YES)
      if command_exists useradd; then
        useradd -m -s /bin/bash "$user"
        log "User '$user' created."
      elif command_exists adduser; then
        adduser --disabled-password --gecos "" "$user"
        log "User '$user' created."
      else
        die "No supported user creation command found (useradd/adduser)."
      fi
      ;;
    *)
      die "Aborted because target user does not exist."
      ;;
  esac
}

prompt_password() {
  local pass1 pass2
  while true; do
    read -r -s -p "Enter new password: " pass1
    printf '\n' >&2
    read -r -s -p "Confirm new password: " pass2
    printf '\n' >&2

    if [[ -z "$pass1" ]]; then
      warn "Password cannot be empty."
      continue
    fi

    if [[ "$pass1" != "$pass2" ]]; then
      warn "Passwords do not match. Try again."
      continue
    fi

    TARGET_PASS="$pass1"
    return 0
  done
}

set_user_password() {
  local user="$1"
  local pass="$2"

  if command_exists chpasswd; then
    printf '%s:%s\n' "$user" "$pass" | chpasswd
  elif command_exists passwd; then
    if passwd --help 2>&1 | grep -q -- '--stdin'; then
      printf '%s\n' "$pass" | passwd --stdin "$user"
    else
      die "chpasswd is missing and passwd --stdin is unsupported."
    fi
  else
    die "Cannot set password: neither chpasswd nor passwd was found."
  fi

  if [[ "$user" == "root" ]] && command_exists passwd; then
    # Some images keep root locked even after provisioning; unlock explicitly.
    passwd -u root >/dev/null 2>&1 || true
  fi

  log "Password updated for user '$user'."
}

build_managed_block() {
  local target_user="$1"

  {
    echo "$MANAGED_BEGIN"
    echo "PasswordAuthentication yes"
    echo "KbdInteractiveAuthentication yes"
    echo "ChallengeResponseAuthentication yes"
    echo "UsePAM yes"
    echo "AuthenticationMethods any"
    if [[ "$target_user" == "root" ]]; then
      echo "PermitRootLogin yes"
    fi
    echo ""
    # Force password auth for this specific user even if other Match rules exist.
    echo "Match User $target_user"
    echo "    PasswordAuthentication yes"
    echo "    KbdInteractiveAuthentication yes"
    echo "    ChallengeResponseAuthentication yes"
    echo "$MANAGED_END"
  }
}

strip_existing_managed_block() {
  local file="$1"
  local begin_count end_count
  local tmp

  begin_count="$(grep -cFx "$MANAGED_BEGIN" "$file" || true)"
  end_count="$(grep -cFx "$MANAGED_END" "$file" || true)"

  if [[ "$begin_count" -ne "$end_count" ]]; then
    die "Managed markers are unbalanced in $file (begin=$begin_count, end=$end_count). Refusing to edit to avoid config corruption."
  fi

  if [[ "$begin_count" -gt 1 ]]; then
    die "Multiple managed blocks detected in $file. Clean up duplicate blocks manually, then rerun."
  fi

  tmp="$(mktemp)"

  awk -v begin="$MANAGED_BEGIN" -v end="$MANAGED_END" '
    $0 == begin {in_block=1; next}
    $0 == end {in_block=0; next}
    !in_block {print}
  ' "$file" > "$tmp"

  cat "$tmp" > "$file"
  rm -f "$tmp"
}

insert_managed_block_before_first_match() {
  local file="$1"
  local block_file="$2"
  local tmp
  tmp="$(mktemp)"

  awk -v block_file="$block_file" '
    BEGIN {
      while ((getline line < block_file) > 0) {
        block = block line "\n"
      }
      close(block_file)
      inserted = 0
    }
    {
      if (!inserted && $0 ~ /^[[:space:]]*[Mm][Aa][Tt][Cc][Hh][[:space:]]+/) {
        printf "%s", block
        inserted = 1
      }
      print
    }
    END {
      if (!inserted) {
        printf "%s", block
      }
    }
  ' "$file" > "$tmp"

  cat "$tmp" > "$file"
  rm -f "$tmp"
}

ensure_cloud_init_ssh_pwauth() {
  local target_user="$1"
  local changed=0
  local cfg

  for cfg in /etc/cloud/cloud.cfg /etc/cloud/cloud.cfg.d/*.cfg; do
    [[ -e "$cfg" ]] || continue

    if grep -Eq '^[[:space:]]*ssh_pwauth[[:space:]]*:' "$cfg"; then
      backup_file "$cfg"
      sed -i.bak-temp -E 's|^[[:space:]]*ssh_pwauth[[:space:]]*:.*$|ssh_pwauth: true|g' "$cfg"
      rm -f "${cfg}.bak-temp"
      changed=1
      log "Updated cloud-init setting in: $cfg"
    fi

    if [[ "$target_user" == "root" ]] && grep -Eq '^[[:space:]]*disable_root[[:space:]]*:[[:space:]]*true[[:space:]]*$' "$cfg"; then
      backup_file "$cfg"
      sed -i.bak-temp -E 's|^[[:space:]]*disable_root[[:space:]]*:[[:space:]]*true[[:space:]]*$|disable_root: false|g' "$cfg"
      rm -f "${cfg}.bak-temp"
      changed=1
      log "Updated cloud-init root policy in: $cfg"
    fi
  done

  if [[ "$changed" -eq 0 ]]; then
    log "No cloud-init ssh_pwauth overrides found."
  fi
}

validate_sshd_config() {
  local sshd_bin="$1"
  local sshd_cfg="$2"

  if "$sshd_bin" -t -f "$sshd_cfg"; then
    return 0
  fi

  # Fallback for older OpenSSH that may fail on AuthenticationMethods in rare cases.
  warn "Config test failed. Retrying without AuthenticationMethods any..."
  sed -i.bak-authmethods '/^[[:space:]]*AuthenticationMethods[[:space:]]\+any[[:space:]]*$/d' "$sshd_cfg"
  rm -f "${sshd_cfg}.bak-authmethods"

  "$sshd_bin" -t -f "$sshd_cfg"
}

restart_sshd() {
  if command_exists systemctl; then
    if systemctl restart sshd 2>/dev/null; then
      log "Restarted service: sshd"
      return 0
    fi
    if systemctl restart ssh 2>/dev/null; then
      log "Restarted service: ssh"
      return 0
    fi
  fi

  if command_exists service; then
    if service sshd restart 2>/dev/null; then
      log "Restarted service: sshd"
      return 0
    fi
    if service ssh restart 2>/dev/null; then
      log "Restarted service: ssh"
      return 0
    fi
  fi

  die "Could not restart ssh service (tried systemctl/service for sshd and ssh)."
}

extract_effective_sshd_config() {
  local sshd_bin="$1"
  local user="$2"
  "$sshd_bin" -T -C "user=$user,host=localhost,addr=127.0.0.1" 2>/dev/null || true
}

effective_has_setting() {
  local effective_cfg="$1"
  local key="$2"
  local expected="$3"
  grep -Eq "^${key}[[:space:]]+${expected}$" <<<"$effective_cfg"
}

detect_ssh_port() {
  local effective_cfg="$1"
  local port
  port="$(awk '/^port[[:space:]]+/ {print $2; exit}' <<<"$effective_cfg")"
  if [[ -z "${port:-}" ]]; then
    port="22"
  fi
  printf '%s\n' "$port"
}

perform_password_login_test() {
  local user="$1"
  local pass="$2"
  local port="$3"
  local token="__SSH_PASSWORD_AUTH_OK__"
  local out

  if ! command_exists ssh; then
    warn "ssh client not found; skipping active login test."
    return 2
  fi

  if ! command_exists sshpass; then
    warn "sshpass is not installed; skipping active login test."
    return 2
  fi

  out="$(SSHPASS="$pass" sshpass -e ssh \
    -o PreferredAuthentications=password \
    -o PubkeyAuthentication=no \
    -o NumberOfPasswordPrompts=1 \
    -o StrictHostKeyChecking=accept-new \
    -o UserKnownHostsFile=/tmp/codex-ssh-known_hosts \
    -o ConnectTimeout=8 \
    -p "$port" \
    "$user@127.0.0.1" \
    "printf '%s\\n' '$token'" 2>&1 || true)"

  if grep -q "$token" <<<"$out"; then
    log "Active SSH password login test passed on 127.0.0.1:$port."
    return 0
  fi

  warn "Active SSH password login test failed. Output:"
  warn "$out"
  return 1
}

run_post_activation_checks() {
  local sshd_bin="$1"
  local target_user="$2"
  local target_pass="$3"

  local effective_cfg ssh_port test_status
  effective_cfg="$(extract_effective_sshd_config "$sshd_bin" "$target_user")"

  if [[ -z "$effective_cfg" ]]; then
    warn "Could not read effective sshd config with -T -C; skipping config-level checks."
  else
    if effective_has_setting "$effective_cfg" "passwordauthentication" "yes"; then
      log "Effective setting check passed: passwordauthentication yes"
    else
      die "Effective setting check failed: passwordauthentication is not yes."
    fi

    if [[ "$target_user" == "root" ]]; then
      if effective_has_setting "$effective_cfg" "permitrootlogin" "yes"; then
        log "Effective setting check passed: permitrootlogin yes"
      else
        die "Effective setting check failed: permitrootlogin is not yes for root."
      fi
    fi
  fi

  ssh_port="$(detect_ssh_port "$effective_cfg")"
  perform_password_login_test "$target_user" "$target_pass" "$ssh_port" || test_status=$?
  test_status="${test_status:-0}"

  if [[ "$test_status" -eq 0 ]]; then
    log "All checks passed."
  elif [[ "$test_status" -eq 2 ]]; then
    warn "Config checks passed, but active login test was skipped."
  else
    die "Config changed, but active password login test failed."
  fi
}

detect_package_manager() {
  if command_exists apt-get; then
    echo "apt"
    return 0
  fi
  if command_exists dnf; then
    echo "dnf"
    return 0
  fi
  if command_exists yum; then
    echo "yum"
    return 0
  fi
  if command_exists zypper; then
    echo "zypper"
    return 0
  fi
  if command_exists pacman; then
    echo "pacman"
    return 0
  fi
  if command_exists apk; then
    echo "apk"
    return 0
  fi
  return 1
}

install_fail2ban_package() {
  local pm="$1"

  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y fail2ban
      ;;
    dnf)
      dnf install -y fail2ban
      ;;
    yum)
      if ! yum install -y fail2ban; then
        warn "Direct fail2ban install failed on yum. Trying EPEL..."
        yum install -y epel-release
        yum install -y fail2ban
      fi
      ;;
    zypper)
      zypper --non-interactive refresh
      zypper --non-interactive install fail2ban
      ;;
    pacman)
      pacman -Sy --noconfirm fail2ban
      ;;
    apk)
      apk add --no-cache fail2ban
      ;;
    *)
      die "Unsupported package manager for fail2ban installation: $pm"
      ;;
  esac
}

write_fail2ban_sshd_jail() {
  local jail_dir="/etc/fail2ban/jail.d"
  local jail_file

  if [[ -d "$jail_dir" ]]; then
    jail_file="${jail_dir}/codex-sshd.local"
  else
    jail_file="/etc/fail2ban/jail.local"
  fi

  backup_file "$jail_file"
  cat > "$jail_file" <<'EOF'
[sshd]
enabled = true
backend = auto
maxretry = 5
findtime = 10m
bantime = 1h
EOF

  log "Fail2ban SSH jail written: $jail_file"
}

restart_fail2ban_service() {
  if command_exists systemctl; then
    if systemctl enable --now fail2ban 2>/dev/null; then
      log "Fail2ban enabled and started with systemctl."
      return 0
    fi
  fi

  if command_exists service; then
    if service fail2ban restart 2>/dev/null; then
      log "Fail2ban restarted with service."
      return 0
    fi
  fi

  if command_exists rc-service; then
    if rc-service fail2ban restart; then
      if command_exists rc-update; then
        rc-update add fail2ban default >/dev/null 2>&1 || true
      fi
      log "Fail2ban restarted with OpenRC."
      return 0
    fi
  fi

  die "Fail2ban installed, but failed to start/restart service."
}

optional_fail2ban_setup() {
  local pm

  if ! prompt_yes_no_default_no "Do you want to install and enable fail2ban for SSH protection?"; then
    log "Skipped fail2ban setup."
    return 0
  fi

  if ! command_exists fail2ban-client; then
    pm="$(detect_package_manager)" || die "No supported package manager found to install fail2ban."
    log "Installing fail2ban with package manager: $pm"
    install_fail2ban_package "$pm"
  else
    log "Fail2ban is already installed."
  fi

  write_fail2ban_sshd_jail
  restart_fail2ban_service

  if command_exists fail2ban-client; then
    if fail2ban-client status sshd >/dev/null 2>&1; then
      log "Fail2ban check passed: sshd jail is active."
    else
      die "Fail2ban service is running, but sshd jail is not active."
    fi
  fi
}

apply_oracle_iptables_cleanup() {
  log "Applying Oracle iptables cleanup (flush + accept policies)."

  if command_exists iptables; then
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -F
    log "iptables cleanup completed."
  else
    warn "iptables command not found; skipping iptables policy/flush steps."
  fi

  if command_exists apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y netfilter-persistent || warn "Failed to purge netfilter-persistent."
  else
    warn "apt-get not found; skipping netfilter-persistent purge."
  fi

  rm -rf /etc/iptables
  log "Removed /etc/iptables (if it existed)."
}

reboot_now() {
  log "Rebooting now to finalize Oracle firewall cleanup..."
  if command_exists systemctl; then
    if systemctl reboot; then
      return 0
    fi
    warn "systemctl reboot failed; trying other reboot methods."
  fi
  if command_exists reboot; then
    if reboot; then
      return 0
    fi
    warn "'reboot' command failed; trying shutdown -r now."
  fi
  if command_exists shutdown; then
    if shutdown -r now; then
      return 0
    fi
  fi
  die "All reboot methods failed (systemctl/reboot/shutdown). Reboot manually."
}

main() {
  require_root

  local sshd_cfg sshd_bin block_file oracle_cleanup
  sshd_cfg="$(pick_sshd_config)"
  sshd_bin="$(pick_sshd_bin)"
  oracle_cleanup="false"

  log "Using sshd config: $sshd_cfg"
  log "Using sshd binary: $sshd_bin"

  if prompt_oracle_firewall_cleanup; then
    oracle_cleanup="true"
    log "Oracle firewall cleanup option enabled."
  else
    log "Oracle firewall cleanup option skipped."
    log "Firewall rules are not modified by this script."
  fi

  prompt_username
  validate_username "$TARGET_USER"
  ensure_user_exists "$TARGET_USER"
  prompt_password

  backup_file "$sshd_cfg"
  strip_existing_managed_block "$sshd_cfg"

  block_file="$(mktemp)"
  build_managed_block "$TARGET_USER" > "$block_file"
  insert_managed_block_before_first_match "$sshd_cfg" "$block_file"
  rm -f "$block_file"

  ensure_cloud_init_ssh_pwauth "$TARGET_USER"

  validate_sshd_config "$sshd_bin" "$sshd_cfg"

  set_user_password "$TARGET_USER" "$TARGET_PASS"
  restart_sshd
  run_post_activation_checks "$sshd_bin" "$TARGET_USER" "$TARGET_PASS"
  optional_fail2ban_setup

  TARGET_PASS=""

  if [[ "$oracle_cleanup" == "true" ]]; then
    apply_oracle_iptables_cleanup
    reboot_now
  fi

  log "Completed successfully. SSH password login is active."
  log "Manual check command: ssh ${TARGET_USER}@<server-ip>"
}

main "$@"
