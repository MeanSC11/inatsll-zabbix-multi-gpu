#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Zabbix GPU (NVIDIA SMI) – Agent-side installer
#   - Supports: zabbix-agent2 and zabbix-agentd (classic)
#   - OS: Linux (Debian/Ubuntu/RHEL-based etc.)
#   - Repo: https://github.com/plambe/zabbix-nvidia-smi-multi-gpu
# ==============================================================================

REPO_RAW="https://raw.githubusercontent.com/plambe/zabbix-nvidia-smi-multi-gpu/master"
SCRIPT_NAME="get_gpus_info.sh"
UPARAM_LINUX="userparameter_nvidia-smi.conf.linux"

require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "[-] Please run as root (sudo)." >&2
    exit 1
  fi
}

has_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_agent() {
  if systemctl list-unit-files | grep -q '^zabbix-agent2\.service'; then
    AGENT_FLAVOR="agent2"
    SERVICE_NAME="zabbix-agent2"
    MAIN_CONF="/etc/zabbix/zabbix_agent2.conf"
    INCLUDE_DIR="/etc/zabbix/zabbix_agent2.d"
    TEST_BIN="zabbix_agent2"
    INCLUDE_LINE="Include=${INCLUDE_DIR}/*.conf"
  elif systemctl list-unit-files | grep -q '^zabbix-agent\.service'; then
    AGENT_FLAVOR="agentd"
    SERVICE_NAME="zabbix-agent"
    MAIN_CONF="/etc/zabbix/zabbix_agentd.conf"
    INCLUDE_DIR="/etc/zabbix/zabbix_agentd.d"
    TEST_BIN="zabbix_agentd"
    INCLUDE_LINE="Include=${INCLUDE_DIR}/*.conf"
  else
    echo "[-] Neither zabbix-agent2 nor zabbix-agent service found." >&2
    echo "    Please install Zabbix Agent first." >&2
    exit 1
  fi
}

fetch() {
  local url="$1" dst="$2"
  if has_cmd curl; then
    curl -fsSL "$url" -o "$dst"
  elif has_cmd wget; then
    wget -qO "$dst" "$url"
  else
    echo "[-] Need curl or wget to download files." >&2
    exit 1
  fi
}

ensure_include_line() {
  # Add Include line if missing
  if ! grep -Eiq "^\s*Include\s*=\s*${INCLUDE_DIR//\//\/}\/\*\.conf" "$MAIN_CONF"; then
    echo "[*] Adding Include line to ${MAIN_CONF}"
    echo "" >> "$MAIN_CONF"
    echo "$INCLUDE_LINE" >> "$MAIN_CONF"
  else
    echo "[*] Include line already present in ${MAIN_CONF}"
  fi
}

main() {
  require_root
  detect_agent

  echo "[*] Detected Zabbix ${AGENT_FLAVOR} (service: ${SERVICE_NAME})"
  echo "[*] Main conf: ${MAIN_CONF}"
  echo "[*] Include dir: ${INCLUDE_DIR}"

  # 0) Quick sanity check for NVIDIA SMI
  if ! has_cmd nvidia-smi; then
    echo "[!] WARNING: 'nvidia-smi' not found in PATH. The template requires NVIDIA driver."
    echo "    Continue anyway… (you can install driver later)."
  else
    echo "[*] nvidia-smi detected: $(command -v nvidia-smi)"
  fi

  # 1) Create dirs
  mkdir -p /etc/zabbix/scripts
  mkdir -p "${INCLUDE_DIR}"

  # 2) Download script + userparameters
  echo "[*] Downloading GPU script → /etc/zabbix/scripts/${SCRIPT_NAME}"
  fetch "${REPO_RAW}/${SCRIPT_NAME}" "/etc/zabbix/scripts/${SCRIPT_NAME}"
  chmod +x "/etc/zabbix/scripts/${SCRIPT_NAME}"

  echo "[*] Downloading userparameters → ${INCLUDE_DIR}/userparameter_nvidia-smi.conf"
  fetch "${REPO_RAW}/${UPARAM_LINUX}" "${INCLUDE_DIR}/userparameter_nvidia-smi.conf"

  # 3) Ensure Include=… in main conf
  ensure_include_line

  # 4) Restart agent
  echo "[*] Restarting ${SERVICE_NAME}"
  systemctl restart "${SERVICE_NAME}"
  systemctl --no-pager --full status "${SERVICE_NAME}" | sed -n '1,20p' || true

  # 5) Quick local test
  echo "[*] Testing userparameter key (local):"
  if has_cmd "${TEST_BIN}"; then
    "${TEST_BIN}" -t gpu.discovery || true
  else
    echo "[!] Cannot find ${TEST_BIN} to self-test key; skipping."
  fi

  cat <<'EOF'

[✓] Done.

Next steps:
  1) Import "zbx_nvidia-smi-multi-gpu.yaml" template into Zabbix Frontend and link it to this host.
  2) From Zabbix Server you can test:
       zabbix_get -s <IP_AGENT> -p 10050 -k gpu.discovery
     (should return JSON with GPU indices/UUIDs)
  3) If 'nvidia-smi' was missing, install NVIDIA driver and ensure:
       which nvidia-smi
       nvidia-smi
EOF
}

main "$@"
