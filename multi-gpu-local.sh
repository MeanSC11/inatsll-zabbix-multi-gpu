#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------
# install-zbx-gpu.sh
# - Base files are vendored in THIS repo under ./raw/ (stable, no upstream path break)
# - (Optional) still clones plambe repo for reference only; failure to clone will NOT break install
# - Idempotent: do NOT overwrite existing files (only create missing files / append missing keys)
# - Adds gpu.unknown_error UserParameter (count of "Unknown Error" lines from nvidia-smi -L)
# - Keeps/ensures nvlink + gpu err keys
# - If userparameter file already exists, MERGE missing UserParameter keys
#   from base ./raw/userparameter_nvidia-smi.conf (key-based, append-only)
# -----------------------------------------

PLAMBE_REPO_URL="${PLAMBE_REPO_URL:-https://github.com/plambe/zabbix-nvidia-smi-multi-gpu.git}"
TMPDIR="${TMPDIR:-/tmp}"
CLONE_DIR=""
QUIET="${QUIET:-0}"
CLONE_PLAMBE="${CLONE_PLAMBE:-1}"  # set 0 to skip cloning upstream reference

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

# Ensure exact key exists; match via regex (so not duplicated)
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

# Merge base userparameters into existing file:
# - Append ONLY UserParameter lines
# - Key-based detection: do not duplicate keys that already exist
# - Never overwrite or edit existing lines
merge_base_userparams() {
  local base_file="$1"
  local target_file="$2"

  [[ -f "$base_file" ]] || die "Base userparameter file not found: $base_file"
  [[ -f "$target_file" ]] || die "Target userparameter file not found: $target_file"

  local line key key_re
  while IFS= read -r line; do
    [[ "$line" =~ ^UserParameter= ]] || continue

    # Key is "UserParameter=xxxx" part before the first comma
    key="$(printf '%s' "$line" | cut -d',' -f1)"   # e.g. UserParameter=gpu.power[*]

    # Escape regex metacharacters for safe grep
    key_re="$(printf '%s\n' "$key" | sed 's/[][\.^$*+?(){}|/]/\\&/g')"

    # If key exists in target, skip
    if grep -Eq "^${key_re}," "$target_file"; then
      continue
    fi

    log "Merge missing key: $key"
    printf "%s\n" "$line" >> "$target_file"
  done < "$base_file"
}

clone_plambe_repo_best_effort() {
  # Upstream clone is optional reference; should never break install.
  if [[ "$CLONE_PLAMBE" != "1" ]]; then
    log "Skip cloning upstream (CLONE_PLAMBE=0)"
    return 0
  fi

  if ! have_cmd git; then
    log "WARN: git not found; skip cloning upstream reference."
    return 0
  fi

  CLONE_DIR="${TMPDIR%/}/zbx-nvidia-smi-multi-gpu.$(date +%s)"
  log "Cloning upstream reference: $PLAMBE_REPO_URL -> $CLONE_DIR"
  if ! git clone --depth 1 "$PLAMBE_REPO_URL" "$CLONE_DIR" >/dev/null 2>&1; then
    log "WARN: git clone upstream failed; continuing with vendored ./raw files."
    CLONE_DIR=""
  fi
}

cleanup() {
  if [[ -n "${CLONE_DIR:-}" && -d "$CLONE_DIR" ]]; then
    rm -rf "$CLONE_DIR" || true
  fi
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

# Best-effort check: warn if Include dirs are not present in main config
warn_if_not_included() {
  local userparam_path="$1"
  local d
  d="$(dirname "$userparam_path")"

  local cfgs=(
    "/etc/zabbix/zabbix_agent2.conf"
    "/etc/zabbix/zabbix_agentd.conf"
    "/etc/zabbix/agent2.conf"
    "/etc/zabbix/agentd.conf"
  )

  local found=0
  for c in "${cfgs[@]}"; do
    [[ -f "$c" ]] || continue
    if grep -Eq "^[[:space:]]*Include[[:space:]]*=/etc/zabbix/zabbix_agent(d|2)\.d/\*\.conf" "$c"; then
      found=1
      break
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    log "WARN: Could not confirm agent Include for: $d/*.conf"
    log "      If gpu.unknown_error shows 'Not supported', verify Include=... in zabbix_agent*.conf"
  fi
}

main() {
  require_root
  trap cleanup EXIT

  # Determine script directory (this repo)
  local SELF_DIR
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

  # Base files from THIS repo (vendored, stable)
  local base_get_gpus="${SELF_DIR}/raw/get_gpus_info.sh"
  local base_userparam="${SELF_DIR}/raw/userparameter_nvidia-smi.conf"

  [[ -f "$base_get_gpus" ]] || die "Base file missing in this repo: $base_get_gpus"
  [[ -f "$base_userparam" ]] || die "Base file missing in this repo: $base_userparam"

  # Optional upstream clone (reference only; should not break)
  clone_plambe_repo_best_effort

  # Target locations
  ensure_dir "/etc/zabbix/scripts"
  ensure_dir "/usr/local/bin"

  # 1) Install get_gpus_info.sh ONLY if missing
  install_file_if_missing "$base_get_gpus" "/etc/zabbix/scripts/get_gpus_info.sh" "0755"

  # 2) Ensure GPU error check script exists (create if missing; never overwrite)
  # NOTE: Your existing configs often reference /usr/local/bin/check_gpu_err_simple.sh
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

  # 3) Install/update userparameter file (IDEMPOTENT + merge)
  local userparam_path
  userparam_path="$(detect_userparam_path)"
  ensure_dir "$(dirname "$userparam_path")"

  # If file doesn't exist, seed it from base repo raw/userparameter_nvidia-smi.conf
  if [[ ! -f "$userparam_path" ]]; then
    log "Seed userparameter file from this repo: $userparam_path"
    install -m 0644 "$base_userparam" "$userparam_path"
  else
    log "Userparameter file exists; will merge missing UserParameter keys from this repo base: $userparam_path"
    merge_base_userparams "$base_userparam" "$userparam_path"
  fi

  # 4) Ensure required lines exist (append-only)
  # ---- Add unknown error counter (requested) ----
  ensure_line_present \
    "$userparam_path" \
    '^UserParameter=gpu\.unknown_error,' \
    "UserParameter=gpu.unknown_error,/usr/bin/nvidia-smi -L 2>&1 | grep -c 'Unknown Error'"

  # ---- Ensure original GPU err + nvlink keys exist ----
  ensure_line_present \
    "$userparam_path" \
    '^UserParameter=nvidia\.gpu\.error,' \
    "UserParameter=nvidia.gpu.error,/usr/local/bin/check_gpu_err_simple.sh"

  # Keep backward compat with your existing nvlink scripts if already present;
  # but also ensure the simple nvlink status key exists.
  ensure_line_present \
    "$userparam_path" \
    '^UserParameter=gpu\.nvlink\.status,' \
    "UserParameter=gpu.nvlink.status,/usr/bin/nvidia-smi nvlink --status"

  # 5) Permissions sanity
  chmod 0644 "$userparam_path" || true

  # Optional warning about include paths
  warn_if_not_included "$userparam_path"

  # 6) Restart agent to apply new UserParameter(s)
  restart_zabbix_agent

  log "Done."
  log "Next in Zabbix: create item key gpu.unknown_error (Numeric) and trigger last(...)>0."
  log "Example trigger: last(/Template Nvidia GPUs Performance/gpu.unknown_error)>0"
}

main "$@"
