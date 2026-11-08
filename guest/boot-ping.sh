#!/bin/bash
# boot-ping: 開機計時的 guest 端 (client)。開機到 multi-user.target 之後, 把 guest 的 uptime 與各里程碑
# (systemd 的 ActiveEnterTimestampMonotonic) 送給 host 上的 boottime.sh。host 沒在聽就直接結束, 不影響開機。
# 安裝 / 移除 (在 host 上執行, 把本檔餵給 guest):
#   ssh <guest> 'sudo bash -s' < guest/boot-ping.sh
#   ssh <guest> 'sudo bash -s -- uninstall' < guest/boot-ping.sh
# 送往: guest 的預設閘道 (QEMU 使用者網路裡就是 host 10.0.2.2) 的 7777 埠; 可在單元裡改 BOOT_PING_HOST / BOOT_PING_PORT。
set -euo pipefail
BIN=/usr/local/bin/boot-ping
UNIT=/etc/systemd/system/boot-ping.service
[ "$(id -u)" = 0 ] || { echo "要用 root 執行 (sudo bash -s)" >&2; exit 1; }

if [ "${1:-}" = "uninstall" ]; then
  systemctl disable boot-ping.service 2>/dev/null || true
  rm -f "$BIN" "$UNIT"
  systemctl daemon-reload
  echo "boot-ping 已移除"
  exit 0
fi

cat > "$BIN" <<'EOF'
#!/bin/bash
# 由 guest/boot-ping.sh 安裝; 開機後送一行 "key=秒數 ..." 給 host。
host=${BOOT_PING_HOST:-$(ip -4 route show default | awk '{print $3; exit}')}
port=${BOOT_PING_PORT:-7777}
[ -n "$host" ] || exit 0
t() { local v; v=$(systemctl show "$1" -P ActiveEnterTimestampMonotonic 2>/dev/null); awk -v v="${v:-0}" 'BEGIN{printf "%.3f", v/1000000}'; }
msg="uptime=$(cut -d' ' -f1 /proc/uptime)"
for u in sysinit.target basic.target ssh.socket network-online.target getty.target multi-user.target graphical.target getty@tty1.service; do
  msg="$msg ${u}=$(t "$u")"
done
for u in $(systemctl list-units 'serial-getty@*.service' --plain --no-legend 2>/dev/null | awk '{print $1}'); do
  msg="$msg ${u}=$(t "$u")"
done
exec 3<>"/dev/tcp/$host/$port" 2>/dev/null || exit 0
echo "$msg" >&3
EOF
chmod 755 "$BIN"

cat > "$UNIT" <<'EOF'
[Unit]
Description=Report boot milestones to the host (boot timing, see boottime.sh)
After=multi-user.target graphical.target network-online.target

[Service]
Type=oneshot
ExecStart=-/usr/bin/timeout 2 /usr/local/bin/boot-ping

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable boot-ping.service
echo "boot-ping 已安裝; 下次開機生效"
