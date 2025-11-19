#!/bin/bash
# ------------------------------------------------------------
# Install GPU error check scripts and Zabbix UserParameters (including NVLink)
# This script creates check_gpu_err_simple.sh and
# appends UserParameter line to userparameter_nvidia-smi.conf
# Author: MeanSC11
# ------------------------------------------------------------
#!/usr/bin/env bash


set -euo pipefail

SCRIPTS_DIR="/etc/zabbix/scripts"
AGENT_D_DIR="/etc/zabbix/zabbix_agent2.d"
CONF_FILE="${AGENT_D_DIR}/gpu_err_check.conf"

# check nvidia-smi
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: nvidia-smi not found in PATH"
  exit 1
fi

echo "[*] Creating scripts directory: ${SCRIPTS_DIR}"
mkdir -p "${SCRIPTS_DIR}"

########################################
# 1) NVLink inactive count
########################################
NVLINK_INACTIVE_SCRIPT="${SCRIPTS_DIR}/nvlink_inactive_count.sh"
echo "[*] Writing ${NVLINK_INACTIVE_SCRIPT}"

cat > "${NVLINK_INACTIVE_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
# Count how many NVLink links are reported as <inactive> or 0.000 GB/s

set -euo pipefail

NVSMI_BIN="$(command -v nvidia-smi)"

# ถ้าไม่มี nvlink subcommand ให้คืนค่า 0 ไป (กัน metric พัง)
if ! "${NVSMI_BIN}" nvlink --status >/dev/null 2>&1; then
  echo 0
  exit 0
fi

# นับจำนวนบรรทัดที่มี <inactive> หรือ 0.000 GB/s
"${NVSMI_BIN}" nvlink --status \
  | grep -E "<inactive>|0\.000 GB/s" \
  | wc -l
EOF

chmod +x "${NVLINK_INACTIVE_SCRIPT}"

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

# ถ้าไม่มี option error-counters ให้คืนค่า 0
if ! "${NVSMI_BIN}" nvlink --error-counters >/dev/null 2>&1; then
  echo 0
  exit 0
fi

# ตัวอย่าง output มีคำว่า "Error Counter:" ท้ายบรรทัด
# เราเก็บตัวเลขสุดท้ายของแต่ละบรรทัดแล้ว sum
"${NVSMI_BIN}" nvlink --error-counters \
  | grep -E "Error Counter" \
  | awk '{sum += $NF} END {print (sum == "" ? 0 : sum)}'
EOF

chmod +x "${NVLINK_ERR_SUM_SCRIPT}"

########################################
# 3) write UserParameters for Zabbix agent2
########################################
echo "[*] Writing Zabbix UserParameters: ${CONF_FILE}"
mkdir -p "${AGENT_D_DIR}"

cat > "${CONF_FILE}" <<EOF
### GPU / NVLink error checks
### Created by install_gpu_err_check.sh

# จำนวน NVLink links ที่ inactive หรือ 0 GB/s
UserParameter=gpu.nvlink.inactive.count,${NVLINK_INACTIVE_SCRIPT}

# จำนวน NVLink error counters รวมทุก link / ทุก GPU
UserParameter=gpu.nvlink.error.sum,${NVLINK_ERR_SUM_SCRIPT}
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

echo "[OK] GPU NVLink error checks installed."
echo "     Test with:"
echo "       zabbix_get -s <HOST_IP> -k gpu.nvlink.inactive.count"
echo "       zabbix_get -s <HOST_IP> -k gpu.nvlink.error.sum"
