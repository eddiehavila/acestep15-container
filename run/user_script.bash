#!/usr/bin/env bash
set -Eeuo pipefail

# ---- config ----
BASE_DIR="/comfy/mnt"

ACE_DIR="$BASE_DIR/ACE-Step-1.5"
ACE_REPO="https://github.com/ACE-Step/ACE-Step-1.5.git"
ACE_VENV="$ACE_DIR/.venv"
ACE_UV="$ACE_VENV/bin/uv"

UI_DIR="$BASE_DIR/ace-step-ui"
UI_REPO="https://github.com/fspecii/ace-step-ui"

API_HOST="0.0.0.0"
API_PORT="8001"
NATIVE_WEBUI_PORT="7860"

LOG_PREFIX="[ace-setup]"

# ---- helpers ----
log() { echo "$LOG_PREFIX $*"; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_root_or_sudo() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    if ! need_cmd sudo; then
      echo "This script requires root or sudo." >&2
      exit 1
    fi
  fi
}

apt_install_if_missing() {
  local pkg="$1"
  if dpkg -s "$pkg" >/dev/null 2>&1; then
    log "Package already installed: $pkg"
  else
    log "Installing package: $pkg"
    DEBIAN_FRONTEND=noninteractive sudo apt-get install -y "$pkg"
  fi
}

git_sync() {
  local repo_url="$1"
  local target_dir="$2"

  if [[ -d "$target_dir/.git" ]]; then
    log "Updating repo in $target_dir (git pull)"
    git -C "$target_dir" fetch --all --prune
    # keep it deterministic for repeat runs
    local branch
    branch="$(git -C "$target_dir" rev-parse --abbrev-ref HEAD)"
    git -C "$target_dir" reset --hard "origin/$branch"
  elif [[ -e "$target_dir" ]]; then
    echo "ERROR: $target_dir exists but is not a git repo. Move it aside or delete it." >&2
    exit 1
  else
    log "Cloning repo into $target_dir"
    git clone "$repo_url" "$target_dir"
  fi
}

ensure_dir() { mkdir -p "$1"; }

stop_existing_api() {
  if need_cmd pgrep; then
    local pids
    pids="$(pgrep -f "acestep-api.*--port[ =]$API_PORT" || true)"
    if [[ -n "${pids:-}" ]]; then
      log "Stopping existing acestep-api on port $API_PORT (pids: $pids)"
      kill $pids || true
      sleep 1
    fi
  fi
}

# ---- main ----
log "Starting as user: $(whoami)"
ensure_root_or_sudo

log "== Installing system packages"
DEBIAN_FRONTEND=noninteractive sudo apt-get update -y
apt_install_if_missing curl
apt_install_if_missing git
apt_install_if_missing ca-certificates
apt_install_if_missing python3
apt_install_if_missing python3-venv
apt_install_if_missing python3-pip

log "== Installing NodeSource Node.js 22 (only if missing / wrong major)"
if ! need_cmd node || ! node -v | grep -qE '^v22\.'; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
  DEBIAN_FRONTEND=noninteractive sudo apt-get install -y nodejs
else
  log "Node.js already installed: $(node -v)"
fi

log "== Sync ACE-Step repo (contained under $ACE_DIR)"
ensure_dir "$BASE_DIR"
git_sync "$ACE_REPO" "$ACE_DIR"

log "== Ensure ACE directories"
ensure_dir "$ACE_DIR/checkpoints"

log "== Ensure ACE venv (contained under $ACE_VENV)"
if [[ ! -d "$ACE_VENV" ]]; then
  log "Creating venv: $ACE_VENV"
  /usr/bin/python3 -m venv "$ACE_VENV"
else
  log "Venv already exists: $ACE_VENV"
fi

log "== Activate ACE venv"
# shellcheck disable=SC1090
source "$ACE_VENV/bin/activate"

log "== Bootstrap python tooling (inside ACE venv only)"
python -m pip install -U pip wheel setuptools

log "== Ensure local uv (inside ACE venv only)"
if [[ ! -x "$ACE_UV" ]]; then
  log "Installing uv into ACE venv"
  pip install -U uv
else
  log "Using existing local uv: $("$ACE_UV" --version || true)"
fi

log "== Install ACE-Step (editable) using local uv"
"$ACE_UV" pip install -e "$ACE_DIR"

log "== Download / sync models using local uv"
# If ACE-Step provides a lockfile / pyproject, uv sync may be useful; harmless if not.
"$ACE_UV" sync || true
"$ACE_UV" run acestep-download --all

log "== Start acestep-api  on port $API_PORT"
stop_existing_api
nohup "$ACE_UV" run acestep-api --server-name "$API_HOST" --port "$API_PORT" \
  > "$ACE_DIR/acestep-api.log" 2>&1 &

log "== Start the 'normal' acestep webui on port $NATIVE_WEBUI_PORT"
nohup "$ACE_UV" run acestep --server-name "$API_HOST" --port "$NATIVE_WEBUI_PORT" \
  > "$ACE_DIR/acestep-native-webui.log" 2>&1 &

log "acestep-api started (log: $ACE_DIR/acestep-api.log)"
log "Waiting a few seconds before proceeding"
sleep 10

log "== Sync ace-step-ui repo (contained under $UI_DIR)"
git_sync "$UI_REPO" "$UI_DIR"

log "== Run UI setup/start (contained under UI dir)"
chmod +x "$UI_DIR/setup.sh" "$UI_DIR/start.sh"

# Run setup every time OR only first time (choose one)
# Option A: run setup only once (recommended):
if [[ ! -f "$UI_DIR/.setup_done" ]]; then
  log "Running UI setup.sh (first run)"
  (cd "$UI_DIR" && ./setup.sh)
  touch "$UI_DIR/.setup_done"
else
  log "UI setup previously completed; skipping setup.sh"
fi

log "Starting UI"
(cd "$UI_DIR" && ./start.sh)

log "== Done. Exiting with 1 to prevent default Comfy start."
exit 1
