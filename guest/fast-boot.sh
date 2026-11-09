#!/bin/bash
# fast-boot: 縮短 guest 開機到 login prompt 的時間 (QEMU 直接開機的 Ubuntu VM; 實測 1.46 秒 -> 約 0.5 秒)。可重複執行。
# 套用 / 還原 (在 host 上執行, 把本檔餵給 guest; 套用後要重開機):
#   ssh <guest> 'sudo bash -s' < guest/fast-boot.sh
#   ssh <guest> 'sudo bash -s -- undo' < guest/fast-boot.sh
# 做了什麼 (各項在 login 關鍵路徑上省下的時間是量到的):
#   /boot/efi 不開機掛載 (noauto,nofail)  直接開機用不到 ESP; 它的 fsck 與掛載擋住 local-fs.target, 約 0.8 秒
#   mask systemd-binfmt                  只註冊 python3.14 的 .pyc 格式, VM 用不到; 實測卡 sysinit 約 1 秒
#   NetworkManager -> systemd-networkd   只有一張 virtio 網卡跑 DHCP; 啟動 121 -> 70 毫秒, 常駐記憶體少約 16 MB
#                                        改用 Type=ether 比對, 不寫死網卡名稱 (PCI 槽位變動時 enpXsY 會變)
#   mask netplan-configure               networkd 直接讀 /etc/systemd/network, 不經 netplan (開機時 30~90 毫秒)
#   停用 fstrim / man-db / logrotate / apt-daily / apt-daily-upgrade 的 timer
#                                        開機時鐘會從映像檔的時間跳到真實時間, Persistent 的 timer 以為錯過排程, 每次開機都補跑
#                                        注意: 關掉 fstrim 後 guest 不會把刪除的空間還給 Mac, 要回收請手動 sudo fstrim -av
# AppArmor 不在這裡: 由 qemu.sh 直接開機的 cmdline 加 apparmor=0, 單元因 ConditionSecurity 自動跳過。
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "要用 root 執行 (sudo bash -s)" >&2; exit 1; }

NET=/etc/systemd/network/10-ether.network
TIMERS="fstrim.timer man-db.timer logrotate.timer apt-daily.timer apt-daily-upgrade.timer"
MASKS="systemd-binfmt.service netplan-configure.service"

if [ "${1:-}" = "undo" ]; then
  sed -i '\#^[^\#].*[[:space:]]/boot/efi[[:space:]]#s/noauto,nofail/defaults/' /etc/fstab
  systemctl unmask $MASKS
  systemctl enable $TIMERS
  rm -f "$NET"
  systemctl disable systemd-networkd 2>/dev/null || true
  systemctl enable NetworkManager NetworkManager-wait-online NetworkManager-dispatcher 2>/dev/null || true
  echo "已還原 (netplan 設定沒動過); 重開機後生效"
  exit 0
fi

# ESP: 選項欄是 defaults 才改 (已改過就不動)
sed -i '\#^[^\#].*[[:space:]]/boot/efi[[:space:]]#s/[[:space:]]defaults[[:space:]]/ noauto,nofail /' /etc/fstab

systemctl mask $MASKS
systemctl disable $TIMERS 2>/dev/null || true

# 網路: networkd 取代 NetworkManager (先寫好設定再切換, 切換在重開機後才生效)
mkdir -p /etc/systemd/network
printf '[Match]\nType=ether\n\n[Network]\nDHCP=yes\n' > "$NET"
systemctl disable NetworkManager NetworkManager-wait-online NetworkManager-dispatcher 2>/dev/null || true
systemctl enable systemd-networkd systemd-resolved
echo "完成; 重開機後生效 (量測: systemd-analyze critical-chain serial-getty@ttyAMA0.service)"
