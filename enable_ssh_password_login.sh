#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
MANAGED_BEGIN="# BEGIN CODEX SSH PASSWORD LOGIN"
MANAGED_END="# END CODEX SSH PASSWORD LOGIN"

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
  local user
  read -r -p "Target username for SSH password login [root]: " user
  user="${user:-root}"
  if [[ -z "$user" ]]; then
    die "Username cannot be empty."
  fi
  printf '%s\n' "$user"
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
    printf '\n'
    read -r -s -p "Confirm new password: " pass2
    printf '\n'

    if [[ -z "$pass1" ]]; then
      warn "Password cannot be empty."
      continue
    fi

    if [[ "$pass1" != "$pass2" ]]; then
      warn "Passwords do not match. Try again."
      continue
    fi

    printf '%s\n' "$pass1"
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
  local tmp
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

main() {
  require_root

  local sshd_cfg sshd_bin target_user target_pass block_file
  sshd_cfg="$(pick_sshd_config)"
  sshd_bin="$(pick_sshd_bin)"

  log "Using sshd config: $sshd_cfg"
  log "Using sshd binary: $sshd_bin"

  target_user="$(prompt_username)"
  ensure_user_exists "$target_user"
  target_pass="$(prompt_password)"

  backup_file "$sshd_cfg"
  strip_existing_managed_block "$sshd_cfg"

  block_file="$(mktemp)"
  build_managed_block "$target_user" > "$block_file"
  insert_managed_block_before_first_match "$sshd_cfg" "$block_file"
  rm -f "$block_file"

  ensure_cloud_init_ssh_pwauth

  validate_sshd_config "$sshd_bin" "$sshd_cfg"

  set_user_password "$target_user" "$target_pass"
  restart_sshd

  log "Completed successfully."
  log "You can now test SSH login with: ssh ${target_user}@<server-ip>"
}

main "$@"
