#!/usr/bin/env bash
# ------------------------------------------------------------
# Install GPU NVLink helper scripts and append Zabbix
# UserParameters into userparameter_nvidia-smi.conf
#
# This script creates:
#   - nvlink_status.sh  (raw NVLink link status)
#   - nvlink_error_sum.sh (sum of NVLink error counters)
#
# And appends two UserParameter entries:
#   gpu.nvlink.status
#   gpu.nvlink.error.sum
#
# Author: MeanSC11
# ------------------------------------------------------------

set -euo pipefail

SCRIPTS_DIR="/etc/zabbix/scripts"
AGENT_D_DIR="/etc/zabbix/zabbix_agent2.d"
CONF_FILE="${AGENT_D_DIR}/userparameter_nvidia-smi.conf"

# Ensure nvidia-smi exists
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found in PATH"
  exit 1
fi

echo "[*] Creating scripts directory: ${SCRIPTS_DIR}"
mkdir -p "${SCRIPTS_DIR}"

########################################
# 1) NVLink status (raw output)
########################################
NVLINK_STATUS_SCRIPT="${SCRIPTS_DIR}/nvlink_status.sh"
echo "[*] Writing ${NVLINK_STATUS_SCRIPT}"

cat > "${NVLINK_STATUS_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
# This script prints the raw NVLink status from:
#     nvidia-smi nvlink --status
#
# Zabbix will store this as a text item, and users can parse it
# using dependent items, regex, or preprocessing rules.

set -euo pipefail

NVSMI_BIN="$(command -v nvidia-smi)"

# If NVLink is not supported or the command fails,
# return empty output to avoid breaking Zabbix checks.
if ! "${NVSMI_BIN}" nvlink --status >/dev/null 2>&1; then
  exit 0
fi

# Output raw NVLink status
"${NVSMI_BIN}" nvlink --status
EOF

chmod +x "${NVLINK_STATUS_SCRIPT}"

########################################
# 2) NVLink error counters sum
########################################
NVLINK_ERR_SUM_SCRIPT="${SCRIPTS_DIR}/nvlink_error_sum.sh"
echo "[*] Writing ${NVLINK_ERR_SUM_SCRIPT}"

cat > "${NVLINK_ERR_SUM_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
# Sum all NVLink error counters (CRC, replay, recovery, etc.)

set -euo pipefail

NVSMI_BIN="$(command -v nvidia-smi)"

# If error-counters is not supported, return 0
if ! "${NVSMI_BIN}" nvlink --error-counters >/dev/null 2>&1; then
  echo 0
  exit 0
fi

# Extract the last numeric value from each "Error Counter" line and sum them
"${NVSMI_BIN}" nvlink --error-counters \
  | grep -E "Error Counter" \
  | awk '{sum += $NF} END {print (sum == "" ? 0 : sum)}'
EOF

chmod +x "${NVLINK_ERR_SUM_SCRIPT}"

########################################
# 3) Append UserParameters to userparameter_nvidia-smi.conf
########################################
echo "[*] Appending UserParameters to ${CONF_FILE}"
mkdir -p "${AGENT_D_DIR}"

cat >> "${CONF_FILE}" <<EOF

### --- NVLink metrics added by install_gpu_err_check.sh ---
# Raw NVLink status (store as text, parse in Zabbix)
UserParameter=gpu.nvlink.status,${NVLINK_STATUS_SCRIPT}

# Sum of all NVLink error counters (all GPUs / all links)
UserParameter=gpu.nvlink.error.sum,${NVLINK_ERR_SUM_SCRIPT}
### --- End NVLink metrics ---
EOF

########################################
# 4) Restart Zabbix agent2
########################################
if systemctl is-enabled zabbix-agent2 >/dev/null 2>&1; then
  echo "[*] Restarting zabbix-agent2"
  systemctl restart zabbix-agent2
else
  echo "[!] zabbix-agent2 service is not enabled or not found. Please restart manually."
fi

echo "[OK] GPU NVLink monitoring installed."
echo "Test with:"
echo "  zabbix_get -s <HOST_IP> -k gpu.nvlink.status"
echo "  zabbix_get -s <HOST_IP> -k gpu.nvlink.error.sum"
