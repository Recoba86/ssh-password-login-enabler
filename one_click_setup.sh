#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
REPO_OWNER="Recoba86"
REPO_NAME="ssh-password-login-enabler"
REPO_BRANCH="${ONE_CLICK_BRANCH:-main}"
SCRIPT_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${REPO_BRANCH}/enable_ssh_password_login.sh"
TMP_SCRIPT="/tmp/enable_ssh_password_login.sh"

log() {
  printf '[%s] %s\n' "$SCRIPT_NAME" "$*"
}

die() {
  printf '[%s] ERROR: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

download_main_script() {
  local url_with_cache_buster="${SCRIPT_URL}?t=$(date +%s)"
  if command_exists curl; then
    curl -fsSL "$url_with_cache_buster" -o "$TMP_SCRIPT"
    return 0
  fi

  if command_exists wget; then
    wget -qO "$TMP_SCRIPT" "$url_with_cache_buster"
    return 0
  fi

  die "Neither curl nor wget is installed."
}

cleanup() {
  rm -f "$TMP_SCRIPT"
}

run_main_script() {
  chmod 700 "$TMP_SCRIPT"

  if [[ "${EUID}" -eq 0 ]]; then
    bash "$TMP_SCRIPT" "$@"
    return 0
  fi

  if command_exists sudo; then
    log "Re-running with sudo..."
    sudo -E bash "$TMP_SCRIPT" "$@"
    return 0
  fi

  die "Run as root or install sudo."
}

main() {
  trap cleanup EXIT

  log "Downloading: $SCRIPT_URL"
  download_main_script
  log "Download complete. Starting setup..."

  run_main_script "$@"

  log "One-click setup finished."
}

main "$@"
