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
#   mask rtkit-daemon                    VM 不需要即時排程提權, 少一個常駐服務 (polkit 不能 mask: 否則進不了 GNOME 桌面)
#   mask systemd-oomd                    只 disable 擋不住: user@.service 的 drop-in 用 Wants= 把它拉起來 (自動登入一開 session 就啟動),
#                                        每次開機背景占用約 0.7 秒 (blame 上很大, 不在 login 路徑上); 代價: 沒有 swap 時不再由 oomd 提早處理記憶體不足
#   停用 unattended-upgrades              少一個常駐服務 (代價: 不自動裝安全更新, 要自己 apt upgrade)
#   停用 fstrim / man-db / logrotate / apt-daily / apt-daily-upgrade 的 timer
#                                        開機時鐘會從映像檔的時間跳到真實時間, Persistent 的 timer 以為錯過排程, 每次開機都補跑
#                                        注意: 關掉 fstrim 後 guest 不會把刪除的空間還給 Mac, 要回收請手動 sudo fstrim -av
#   開機早期載入 virtio_rng               vz.sh (Virtualization.framework) 不像 QEMU 在 device tree 給 rng-seed, 隨機數池要等 udev 才載入
#                                        virtio_rng 後才初始化; systemd-random-seed 與 systemd-resolved 各卡約 0.5 秒 (QEMU 只要 6 / 40 毫秒),
#                                        systemd-modules-load 在 0.25 秒就載入它; vz 開機 1.17 -> 0.55 秒 (QEMU 不受影響, 加了也無害)
# AppArmor 不在這裡: 由 qemu.sh 直接開機的 cmdline 加 apparmor=0, 單元因 ConditionSecurity 自動跳過。
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "要用 root 執行 (sudo bash -s)" >&2; exit 1; }

NET=/etc/systemd/network/10-ether.network
RNG=/etc/modules-load.d/virtio-rng.conf
TIMERS="fstrim.timer man-db.timer logrotate.timer apt-daily.timer apt-daily-upgrade.timer"
MASKS="systemd-binfmt.service netplan-configure.service rtkit-daemon.service systemd-oomd.service systemd-oomd.socket"
SERVICES="systemd-oomd.service unattended-upgrades.service"

if [ "${1:-}" = "undo" ]; then
  sed -i '\#^[^\#].*[[:space:]]/boot/efi[[:space:]]#s/noauto,nofail/defaults/' /etc/fstab
  systemctl unmask $MASKS
  systemctl enable $TIMERS $SERVICES
  rm -f "$NET" "$RNG"
  systemctl disable systemd-networkd 2>/dev/null || true
  systemctl enable NetworkManager NetworkManager-wait-online NetworkManager-dispatcher 2>/dev/null || true
  echo "已還原 (netplan 設定沒動過); 重開機後生效"
  exit 0
fi

# ESP: 選項欄是 defaults 才改 (已改過就不動)
sed -i '\#^[^\#].*[[:space:]]/boot/efi[[:space:]]#s/[[:space:]]defaults[[:space:]]/ noauto,nofail /' /etc/fstab

systemctl mask $MASKS
systemctl disable $TIMERS $SERVICES 2>/dev/null || true

# 隨機數: 早期載入 virtio_rng (見上面說明)
mkdir -p /etc/modules-load.d
echo virtio_rng > "$RNG"

# 網路: networkd 取代 NetworkManager (先寫好設定再切換, 切換在重開機後才生效)
mkdir -p /etc/systemd/network
printf '[Match]\nType=ether\n\n[Network]\nDHCP=yes\n' > "$NET"
systemctl disable NetworkManager NetworkManager-wait-online NetworkManager-dispatcher 2>/dev/null || true
systemctl enable systemd-networkd systemd-resolved
echo "完成; 重開機後生效 (量測: systemd-analyze critical-chain serial-getty@ttyAMA0.service)"
