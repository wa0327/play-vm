#!/bin/bash
# vfkit (Apple Virtualization.framework) 啟動器
# 用法:  ./vfkit.sh <os> [模式] [選項]
#   <os>    OS 目錄名稱 (該目錄下要有 vfkit/vfkit.conf), 例如 ubuntu
#   模式    (空)      正常開機 (有圖形視窗)
#           install   第一次安裝 (掛載安裝光碟; 磁碟不存在時自動建立稀疏 raw 檔)
#           ip        查這台 VM 目前的 IP (從 /var/db/dhcpd_leases, 用 vfkit.conf 的 MAC)
#           extract   從磁碟離線取出 kernel/initrd/開機參數, 存到 <os>/vfkit/direct/ (給 --direct 用; 要先 brew install e2fsprogs; VM 要先關機)
# 選項:  --res 寬x高   解析度, 例如 --res 1440x900 (預設見 vfkit.conf)
#        --headless    不開視窗 (用 ssh 連線; 搭配 --direct 時終端機會直接接上 VM 的主控台)
#        --direct      直接載入 kernel 開機, 略過 UEFI/GRUB (先跑一次 extract; 或在 vfkit.conf 自行設 KERNEL/INITRD/CMDLINE)
#                      流程: ./vfkit.sh <os> install  ->  ./vfkit.sh <os> extract  ->  ./vfkit.sh <os> --direct
#                      VM 裡升級 kernel 後要重跑 extract, 否則 --direct 還是開舊的 kernel
#        --dry-run     只印出 vfkit 參數, 不啟動                   -h, --help  顯示說明
# 各 OS 的差異放在 <os>/vfkit/vfkit.conf, 路徑相對於 <os>/vfkit/ (共用的安裝光碟在上一層 ../)。
# 注意: vfkit 只支援 raw 磁碟 (不支援 qcow2); 在 VM 裡正常關機, 不要直接 Ctrl+C (等於斷電)。
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

usage() {
  sed -n '2,/^set -euo/p' "$ROOT/vfkit.sh" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  echo "可用的 OS:" >&2
  for c in "$ROOT"/*/vfkit/vfkit.conf; do [ -f "$c" ] && echo "  $(basename "$(dirname "$(dirname "$c")")")" >&2; done
  exit "${1:-1}"
}

# --- 參數解析 (選項可放在任何位置; 第一個非選項是 <os>, 第二個是 [模式]) ---
OPT_HEADLESS=0; OPT_DRY=0; OPT_RES=""; OPT_DIRECT=0
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --headless) OPT_HEADLESS=1 ;;
    --dry-run)  OPT_DRY=1 ;;
    --direct)   OPT_DIRECT=1 ;;
    --res)      shift; OPT_RES="${1:-}" ;;
    --res=*)    OPT_RES="${1#--res=}" ;;
    -h|--help)  usage 0 ;;
    -*)         echo "未知選項: $1" >&2; usage ;;
    *)          POS+=("$1") ;;
  esac
  shift
done
if [ -n "$OPT_RES" ] && ! [[ "$OPT_RES" =~ ^[0-9]+x[0-9]+$ ]]; then echo "--res 格式要像 1920x1200 (目前: $OPT_RES)" >&2; exit 1; fi
OS="${POS[0]:-}"; MODE="${POS[1]:-}"
[ -n "$OS" ] || usage
OS="${OS%/}"
if [ ! -f "$OS/vfkit/vfkit.conf" ]; then
  echo "找不到 $OS/vfkit/vfkit.conf ($OS 沒有 vfkit 這條路; 例如 Windows 不適用 Virtualization.framework)" >&2
  usage
fi
case "$MODE" in ""|install|ip|extract) ;; *) echo "未知模式: $MODE" >&2; usage ;; esac

# --- 預設值 (vfkit.conf 可覆蓋) ---
NAME="$OS"
DISK=disk.img; DISK_SIZE=64G
DISK_BUS=virtio-blk                # virtio-blk (Linux) | nvme (Windows 內建驅動)
VARS=vars.fd
INSTALL_ISO=""
CPUS=4; MEMORY_MB=4096
XRES=1920; YRES=1200
MAC=""
SHARES=()
DIRECT_DIR=direct                  # extract 的輸出資料夾 (相對於 <os>/vfkit/): Image、initrd.img、cmdline (GRUB 原始值)
KERNEL=""; INITRD=""; CMDLINE=""   # 只在 --direct 使用; 沒設定就用 $DIRECT_DIR 裡 extract 取出的 (vfkit.conf 設了就以 conf 為準; CMDLINE 不能含逗號)
cd "$OS/vfkit"
# shellcheck disable=SC1091
source ./vfkit.conf
if [ -n "$OPT_RES" ]; then XRES="${OPT_RES%x*}"; YRES="${OPT_RES#*x}"; fi   # --res 優先於 vfkit.conf

# macOS 的 /var/db/dhcpd_leases 會省略 MAC 每一段的前導零 (52:54:00:aa:bb:01 -> 52:54:0:aa:bb:1)
SHORT_MAC=""
if [ -n "$MAC" ]; then SHORT_MAC="$(echo "$MAC" | tr 'A-F' 'a-f' | sed -E 's/(^|:)0+([0-9a-f])/\1\2/g')"; fi

# --- ip 模式: 從 DHCP 租約找這台 VM 的 IP (取最後一筆) ---
if [ "$MODE" = "ip" ]; then
  [ -n "$SHORT_MAC" ] || { echo "$OS/vfkit/vfkit.conf 沒有設定 MAC, 無法查 IP" >&2; exit 1; }
  ip="$(awk -v mac="1,$SHORT_MAC" 'BEGIN{RS="}"} index($0, "hw_address=" mac) {if (match($0, /ip_address=[0-9.]+/)) last=substr($0, RSTART+11, RLENGTH-11)} END{print last}' /var/db/dhcpd_leases 2>/dev/null)"
  [ -n "$ip" ] || { echo "租約裡找不到 $MAC (VM 還沒開機, 或還沒取得 IP)" >&2; exit 1; }
  echo "$ip"
  exit 0
fi

# --- extract: 不開機, 直接從磁碟離線取出 kernel / initrd / 開機參數 (給 --direct 用) ---
# 實作在共用的 _extract.sh (qemu.sh 也用它); 這裡的磁碟是 raw (直接讀, 不用轉換)。
# raw 磁碟沒有檔案鎖, VM 還在跑時讀到的內容可能不一致, 所以先擋下。
if [ "$MODE" = "extract" ]; then
  [ -f "$DISK" ] || { echo "找不到磁碟 $OS/vfkit/$DISK; 第一次請先  ./vfkit.sh $OS install" >&2; exit 1; }
  if [ -f vfkit.pid ] && kill -0 "$(cat vfkit.pid)" 2>/dev/null; then
    echo "$NAME 還在執行 (pid $(cat vfkit.pid)), 請先在 VM 裡關機再 extract" >&2; exit 1
  fi
  "$ROOT/_extract.sh" raw "$PWD/$DISK" "$PWD/$DIRECT_DIR"
  echo "下一步: ./vfkit.sh $OS --direct   (VM 裡升級 kernel 後要重跑  ./vfkit.sh $OS extract)"
  exit 0
fi

case "$DISK_BUS" in virtio-blk|nvme) ;; *) echo "$OS/vfkit/vfkit.conf 的 DISK_BUS 只能是 virtio-blk 或 nvme (目前: $DISK_BUS)" >&2; exit 1 ;; esac

if [ "$OPT_DIRECT" = "1" ]; then
  [ "$MODE" != "install" ] || { echo "--direct 不能搭配 install (安裝要走 UEFI 才能從光碟開機)" >&2; exit 1; }
  # vfkit.conf 沒設定的項目, 用 extract 取出的檔案補上
  if [ -z "$KERNEL" ] && [ -f "$DIRECT_DIR/Image" ]; then KERNEL="$DIRECT_DIR/Image"; fi
  if [ -z "$INITRD" ] && [ -f "$DIRECT_DIR/initrd.img" ]; then INITRD="$DIRECT_DIR/initrd.img"; fi
  # 開機參數的底: vfkit.conf 的 CMDLINE, 沒設就用 extract 取出的原始值 (GRUB 那行, 一個字都沒改)
  if [ -z "$CMDLINE" ]; then
    if [ -f "$DIRECT_DIR/cmdline" ]; then CMDLINE="$(cat "$DIRECT_DIR/cmdline")"; else CMDLINE="ro"; fi
  fi
  # 增刪修:
  #   刪: crashkernel= (含逗號, 而且 kdump 在這沒用)、splash / vt.handoff / $變數 (GRUB 圖形開機畫面用, 直接開機不會展開)、console= (下面重附)
  #   加: console= 依模式附加。hvc0 = virtio-serial (--headless 接終端機), tty0 = kernel VT (有視窗, virtio-gpu 才看得到)
  #       最後一個 console= 才是 /dev/console: 有視窗 tty0 放最後, 無視窗 hvc0 放最後
  _cl=""
  for _w in $CMDLINE; do
    case "$_w" in crashkernel=*|splash|vt.handoff*|\$*|console=*) ;; *) _cl="$_cl $_w" ;; esac
  done
  if [ "$OPT_HEADLESS" = "1" ]; then CMDLINE="${_cl# } console=tty0 console=hvc0"
  else CMDLINE="${_cl# } console=hvc0 console=tty0"; fi
  [ -n "$KERNEL" ] && [ -n "$INITRD" ] || { echo "--direct 找不到 kernel/initrd: 先跑  ./vfkit.sh $OS extract  (或在 $OS/vfkit/vfkit.conf 設定 KERNEL 和 INITRD)" >&2; exit 1; }
  case "$CMDLINE" in *,*) echo "CMDLINE 不能含逗號 (vfkit 以逗號分隔選項): $CMDLINE" >&2; exit 1 ;; esac
  if [ "$OPT_DRY" != "1" ]; then
    for f in "$KERNEL" "$INITRD"; do [ -f "$f" ] || { echo "找不到 $f" >&2; exit 1; }; done
  fi
fi

PIDFILE=vfkit.pid
DRY="$OPT_DRY"

# --- 防止同一個磁碟被兩個 VM 同時使用 ---
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "$NAME 已經在執行 (pid $(cat "$PIDFILE")), 不重複啟動" >&2
  exit 1
fi

# --- 磁碟 (raw, 稀疏檔) ---
if [ ! -f "$DISK" ]; then
  if [ "$MODE" = "install" ]; then
    if [ "$DRY" = "1" ]; then echo "(--dry-run: 會建立 $DISK_SIZE 稀疏磁碟 $OS/vfkit/$DISK)" >&2; else truncate -s "$DISK_SIZE" "$DISK"; fi
  else
    echo "找不到磁碟 $OS/vfkit/$DISK; 第一次請用  ./vfkit.sh $OS install" >&2; exit 1
  fi
fi
if [ "$MODE" = "install" ]; then
  [ -n "$INSTALL_ISO" ] && [ -f "$INSTALL_ISO" ] || { echo "找不到安裝光碟: ${INSTALL_ISO:-(INSTALL_ISO 未設定)}" >&2; exit 1; }
fi

# --- 組參數 ---
BOOTLOADER="efi,variable-store=$VARS,create"
if [ "$OPT_DIRECT" = "1" ]; then BOOTLOADER="linux,kernel=$KERNEL,initrd=$INITRD,cmdline=$CMDLINE"; fi
ARGS=(
  --cpus "$CPUS"
  --memory "$MEMORY_MB"
  --bootloader "$BOOTLOADER"
  --device "$DISK_BUS,path=$DISK"
)
NET="virtio-net,nat"
if [ -n "$MAC" ]; then NET="$NET,mac=$MAC"; fi
ARGS+=(--device "$NET" --device virtio-rng)

# 共享資料夾 (virtio-fs; vfkit 沒有唯讀選項): SHARES=("標籤:路徑"), VM 內 mount -t virtiofs <標籤> <掛載點>
for entry in ${SHARES[@]+"${SHARES[@]}"}; do
  tag="${entry%%:*}"; path="${entry#*:}"
  if [ ! -d "$path" ]; then echo "略過共享 $tag: 資料夾不存在 ($path)" >&2; continue; fi
  ARGS+=(--device "virtio-fs,sharedDir=$path,mountTag=$tag")
  echo "共享: $tag <- $path   (VM 內: sudo mount -t virtiofs $tag /mnt/$tag)" >&2
done

if [ "$MODE" = "install" ]; then
  ARGS+=(--device "usb-mass-storage,path=$INSTALL_ISO,readonly")
fi

if [ "$OPT_HEADLESS" != "1" ]; then
  ARGS+=(
    --device virtio-input,keyboard
    --device virtio-input,pointing
    --device "virtio-gpu,width=$XRES,height=$YRES"
    --gui
  )
fi
# 直接開機沒有 UEFI 畫面, 無視窗時把終端機接上 VM 的主控台 (kernel 要有 console=hvc0; 需要真的終端機, 管線不行)
if [ "$OPT_DIRECT" = "1" ] && [ "$OPT_HEADLESS" = "1" ]; then ARGS+=(--device virtio-serial,stdio); fi
ARGS+=(--pidfile "$PIDFILE")

if [ -n "$MAC" ] && [ "$DRY" != "1" ]; then
  echo "提示: 開機後用  ./vfkit.sh $OS ip  查 IP" >&2
fi

if [ "$DRY" = "1" ]; then
  printf '%s\n' vfkit "${ARGS[@]}"
  exit 0
fi

trap 'rm -f -- vfkit.pid' EXIT
vfkit "${ARGS[@]}"
