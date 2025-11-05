#!/bin/bash
# ------------------------------------------------------------
# GPU ERR! detection setup for Zabbix Agent2
# This script creates check_gpu_err_simple.sh and
# appends UserParameter line to userparameter_nvidia-smi.conf
# ------------------------------------------------------------

SCRIPT_PATH="/usr/local/bin/check_gpu_err_simple.sh"
CONF_PATH="/etc/zabbix/zabbix_agent2.d/userparameter_nvidia-smi.conf"
AGENT_SERVICE="zabbix-agent2"
NVIDIA_SMI="/usr/bin/nvidia-smi"

echo "Installing GPU ERR! detection for Zabbix Agent2..."
echo "----------------------------------------------------"

# 1. Create script to check for ERR! in nvidia-smi output
cat << 'EOF' > $SCRIPT_PATH
#!/bin/bash
# Return 1 if nvidia-smi output contains "ERR!", else 0.

NVIDIA_SMI="/usr/bin/nvidia-smi"

# If nvidia-smi not found, return 0
if [ ! -x "$NVIDIA_SMI" ]; then
  echo 0
  exit 0
fi

# Check for ERR!
"$NVIDIA_SMI" 2>/dev/null | grep -q "ERR!"
if [ $? -eq 0 ]; then
  echo 1    # Error found
else
  echo 0    # Normal
fi
EOF

chmod 755 $SCRIPT_PATH
chown root:root $SCRIPT_PATH

echo "Created $SCRIPT_PATH"

# 2. Add UserParameter line (append only if not exists)
if ! grep -q "nvidia.gpu.error" "$CONF_PATH" 2>/dev/null; then
  echo "UserParameter=nvidia.gpu.error,$SCRIPT_PATH" >> "$CONF_PATH"
  echo "Appended UserParameter to $CONF_PATH"
else
  echo "UserParameter already exists in $CONF_PATH"
fi

chmod 644 $CONF_PATH
chown root:root $CONF_PATH

# 3. Restart Zabbix Agent2 service
if systemctl is-active --quiet $AGENT_SERVICE; then
  systemctl restart $AGENT_SERVICE
  echo "Restarted $AGENT_SERVICE successfully."
else
  echo "Warning: $AGENT_SERVICE not running or not found. Please start it manually."
fi

# 4. Test output
echo "----------------------------------------------------"
echo "Testing command output..."
$SCRIPT_PATH
echo "----------------------------------------------------"
echo "Installation complete."
echo "You can test from Zabbix server using:"
echo "  zabbix_get -s <agent_ip> -k nvidia.gpu.error"
