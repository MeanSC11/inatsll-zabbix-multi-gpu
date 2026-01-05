#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------
# install-zbx-gpu.sh
# - Base from plambe/zabbix-nvidia-smi-multi-gpu
# - Idempotent: do NOT overwrite existing files
#   (only append missing lines / create missing files)
# - Add gpu.unknown_error UserParameter (count)
# - Keep nvlink + gpu err checks (original style)
# -----------------------------------------

PLAMBE_REPO_URL="${PLAMBE_REPO_URL:-https://github.com/plambe/zabbix-nvidia-smi-multi-gpu.git}"
TMPDIR="${TMPDIR:-/tmp}"
CLONE_DIR=""
QUIET="${QUIET:-0}"

log() {
  if [[ "$QUIET" != "1" ]]; then
    echo "[install-zbx-gpu] $*"
  fi
}

die() {
  echo "[install-zbx-gpu] ERROR: $*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Please run as root (sudo)."
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

# Choose best destination for userparameter file.
# Preference:
# 1) if existing file found in agent2.d or agentd.d -> use it
# 2) else if agent2.d exists -> use it
# 3) else use agentd.d
detect_userparam_path() {
  local p1="/etc/zabbix/zabbix_agent2.d/userparameter_nvidia-smi.conf"
  local p2="/etc/zabbix/zabbix_agentd.d/userparameter_nvidia-smi.conf"

  if [[ -f "$p1" ]]; then
    echo "$p1"; return
  fi
  if [[ -f "$p2" ]]; then
    echo "$p2"; return
  fi
  if [[ -d "/etc/zabbix/zabbix_agent2.d" ]]; then
    echo "$p1"; return
  fi
  echo "$p2"
}

# Ensure directory exists
ensure_dir() {
  local d="$1"
  if [[ ! -d "$d" ]]; then
    log "Create dir: $d"
    install -d -m 0755 "$d"
  fi
}

# Copy file if missing (no overwrite)
install_file_if_missing() {
  local src="$1"
  local dst="$2"
  local mode="${3:-0755}"

  if [[ -f "$dst" ]]; then
    log "Keep existing file (no overwrite): $dst"
    return 0
  fi

  log "Install file: $dst"
  install -m "$mode" "$src" "$dst"
}

# Ensure exact line exists; match via regex (so not duplicated)
ensure_line_present() {
  local file="$1"
  local match_regex="$2"
  local line="$3"

  if [[ -f "$file" ]] && grep -Eq "$match_regex" "$file"; then
    log "Line already present in $file (match: $match_regex)"
    return 0
  fi

  log "Append line to $file: $line"
  printf "%s\n" "$line" >> "$file"
}

# Ensure file exists (touch), without overwriting
ensure_file_exists() {
  local file="$1"
  local header_comment="${2:-}"

  if [[ -f "$file" ]]; then
    return 0
  fi

  log "Create new file: $file"
  touch "$file"
  chmod 0644 "$file"

  if [[ -n "$header_comment" ]]; then
    printf "%s\n" "$header_comment" >> "$file"
  fi
}

clone_plambe_repo() {
  have_cmd git || die "git is required. Please install git."
  CLONE_DIR="${TMPDIR%/}/zbx-nvidia-smi-multi-gpu.$(date +%s)"
  log "Cloning base repo: $PLAMBE_REPO_URL -> $CLONE_DIR"
  git clone --depth 1 "$PLAMBE_REPO_URL" "$CLONE_DIR" >/dev/null 2>&1 || die "git clone failed"
}

# Restart agent (agent2 preferred if exists)
restart_zabbix_agent() {
  local restarted=0

  if systemctl list-unit-files 2>/dev/null | grep -q '^zabbix-agent2\.service'; then
    log "Restarting zabbix-agent2"
    systemctl restart zabbix-agent2
    restarted=1
  fi

  if [[ "$restarted" -eq 0 ]] && systemctl list-unit-files 2>/dev/null | grep -q '^zabbix-agent\.service'; then
    log "Restarting zabbix-agent"
    systemctl restart zabbix-agent
    restarted=1
  fi

  if [[ "$restarted" -eq 0 ]]; then
    log "WARN: Could not detect zabbix-agent service name; please restart agent manually."
  fi
}

main() {
  require_root
  clone_plambe_repo

  # Paths from base repo
  local base_get_gpus="${CLONE_DIR}/raw/get_gpus_info.sh"
  local base_userparam="${CLONE_DIR}/raw/userparameter_nvidia-smi.conf"

  [[ -f "$base_get_gpus" ]] || die "Base file missing: $base_get_gpus"
  [[ -f "$base_userparam" ]] || die "Base file missing: $base_userparam"

  # Target locations (as per base repo convention)
  ensure_dir "/etc/zabbix/scripts"
  ensure_dir "/usr/local/bin"

  # 1) Install get_gpus_info.sh ONLY if missing
  install_file_if_missing "$base_get_gpus" "/etc/zabbix/scripts/get_gpus_info.sh" "0755"

  # 2) Ensure GPU error check script exists if referenced by existing config
  #    We keep original key name in config (nvidia.gpu.error) but script path may vary.
  #    If user already has /usr/local/bin/check_gpu_err_simple.sh -> do nothing.
  if [[ ! -f "/usr/local/bin/check_gpu_err_simple.sh" ]]; then
    log "Create /usr/local/bin/check_gpu_err_simple.sh (missing)."
    cat > /usr/local/bin/check_gpu_err_simple.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# 0=OK, 1=problem detected
# Lightweight heuristic: check kernel log for NVIDIA Xid / NVML errors.
window_minutes="${WINDOW_MINUTES:-10}"
if command -v journalctl >/dev/null 2>&1; then
  if journalctl -k --since "${window_minutes} min ago" 2>/dev/null | grep -Eqi 'NVRM: Xid|Xid \(|NVML:|Unable to determine the device handle|Unknown Error'; then
    echo 1; exit 0
  fi
else
  if dmesg 2>/dev/null | tail -n 2000 | grep -Eqi 'NVRM: Xid|Xid \(|NVML:|Unable to determine the device handle|Unknown Error'; then
    echo 1; exit 0
  fi
fi
echo 0
EOF
    chmod 0755 /usr/local/bin/check_gpu_err_simple.sh
  else
    log "Keep existing: /usr/local/bin/check_gpu_err_simple.sh"
  fi

  # 3) Install/update userparameter file (IDEMPOTENT)
  local userparam_path
  userparam_path="$(detect_userparam_path)"
  ensure_dir "$(dirname "$userparam_path")"

  # If file doesn't exist, seed it from base repo raw/userparameter_nvidia-smi.conf
  if [[ ! -f "$userparam_path" ]]; then
    log "Seed userparameter file from base repo: $userparam_path"
    install -m 0644 "$base_userparam" "$userparam_path"
  else
    log "Userparameter file exists; will only append missing lines: $userparam_path"
  fi

  # 4) Ensure required lines exist (without overwriting)
  # ---- Add unknown error counter (requested) ----
  ensure_line_present \
    "$userparam_path" \
    '^UserParameter=gpu\.unknown_error,' \
    "UserParameter=gpu.unknown_error,/usr/bin/nvidia-smi -L 2>&1 | grep -c 'Unknown Error'"

  # ---- Ensure original GPU err + nvlink keys exist (per your existing convention) ----
  # If already present, keep.
  ensure_line_present \
    "$userparam_path" \
    '^UserParameter=nvidia\.gpu\.error,' \
    "UserParameter=nvidia.gpu.error,/usr/local/bin/check_gpu_err_simple.sh"

  ensure_line_present \
    "$userparam_path" \
    '^UserParameter=gpu\.nvlink\.status,' \
    "UserParameter=gpu.nvlink.status,/usr/bin/nvidia-smi nvlink --status"

  # 5) Permissions sanity
  chmod 0644 "$userparam_path" || true

  # 6) Restart agent to apply new UserParameter(s)
  restart_zabbix_agent

  log "Done."
  log "Next in Zabbix: create item key gpu.unknown_error (Numeric) and trigger last(...)>0."
  log "Example trigger: last(/Template Nvidia GPUs Performance/gpu.unknown_error)>0"
}

main "$@"
