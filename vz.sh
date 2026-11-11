#!/bin/bash
# Virtualization.framework 啟動器 (Swift 程式在 vz/, 這裡負責解析選項、組開機參數、編譯與簽章)
# 用法:  ./vz.sh <os> [模式] [選項]
#   <os>    OS 目錄名稱 (該目錄下要有 vz/vz.conf), 例如 ubuntu
#   模式    (空)      正常開機 (預設直接載入 kernel, 略過 UEFI/GRUB)
#           install   第一次安裝 (UEFI 開機, 掛載安裝光碟; 磁碟不存在時建立稀疏 raw 檔)
#           ip        查這台 VM 目前的 IP (從 /var/db/dhcpd_leases, 用 vz.conf 的 MAC)
# 選項:  --graphical  開視窗並加顯示卡, 開機目標用 graphical (預設: 無視窗, multi-user, 只用這個終端機)
#        --res 寬x高   解析度 (預設見 vz.conf)         --mic   加麥克風 (macOS 會詢問權限)
#        --no-share   這次不共享資料夾                 --efi   強制走 UEFI/GRUB (預設有 <os> 的 direct/ 資料夾就直接開機)
#        --dry-run    只印出參數, 不啟動                -h, --help  顯示說明
# 終端機接 guest 的 hvc0 (virtio console): Ctrl-A p 請 guest 正常關機 (等於按電源鍵), Ctrl-A x 強制結束 (等於斷電), 在 guest 按 Ctrl-C 不會殺掉 VM。
# 視窗模式下 Cmd-Q / 關視窗 = 請 guest 正常關機。kill (SIGTERM) 同理。
# 直接開機的 kernel 用 ./qemu.sh <os> extract 產生 (或在 vz.conf 設 KERNEL/ROOTDEV/CMDLINE/INITRD)。
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

usage() {
  sed -n '2,/^set -euo/p' "$ROOT/vz.sh" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  echo "可用的 OS:" >&2
  for c in "$ROOT"/*/vz/vz.conf; do [ -f "$c" ] && echo "  $(basename "$(dirname "$(dirname "$c")")")" >&2; done
  exit "${1:-1}"
}

OPT_GUI=0; OPT_MIC=0; OPT_SHARE=1; OPT_DRY=0; OPT_RES=""; OPT_EFI=0
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --graphical) OPT_GUI=1 ;;
    --mic)      OPT_MIC=1 ;;
    --no-share) OPT_SHARE=0 ;;
    --efi)      OPT_EFI=1 ;;
    --dry-run)  OPT_DRY=1 ;;
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
[ -f "$OS/vz/vz.conf" ] || { echo "找不到 $OS/vz/vz.conf" >&2; usage; }
case "$MODE" in ""|install|ip) ;; *) echo "未知模式: $MODE" >&2; usage ;; esac

# --- 預設值 (vz.conf 可覆蓋) ---
NAME="$OS"
DISK=disk.raw; DISK_SIZE=64G
VARS=vars.fd
INSTALL_ISO=""
CPUS=10; MEMORY_MB=8192
XRES=1920; YRES=1200
MAC=""
SHARES=()
HOSTFWD=()
DIRECT_DIR=direct
KERNEL=""; INITRD=""; ROOTDEV=""; CMDLINE=""
cd "$OS/vz"
# shellcheck disable=SC1091
source ./vz.conf
if [ -n "$OPT_RES" ]; then XRES="${OPT_RES%x*}"; YRES="${OPT_RES#*x}"; fi

# --- ip 模式 (macOS 的 dhcpd_leases 會省略 MAC 每一段的前導零) ---
if [ "$MODE" = "ip" ]; then
  [ -n "$MAC" ] || { echo "$OS/vz/vz.conf 沒有設定 MAC, 無法查 IP" >&2; exit 1; }
  short="$(echo "$MAC" | tr 'A-F' 'a-f' | sed -E 's/(^|:)0+([0-9a-f])/\1\2/g')"
  ip="$(awk -v mac="1,$short" 'BEGIN{RS="}"} index($0, "hw_address=" mac) {if (match($0, /ip_address=[0-9.]+/)) last=substr($0, RSTART+11, RLENGTH-11)} END{print last}' /var/db/dhcpd_leases 2>/dev/null)"
  [ -n "$ip" ] || { echo "租約裡找不到 $MAC (VM 還沒開機, 或還沒取得 IP)" >&2; exit 1; }
  echo "$ip"; exit 0
fi

# --- 磁碟使用中檢查: lsof 要約 50 毫秒, 放背景跟後面的步驟重疊 ---
LSOF_PID=""
if [ "$OPT_DRY" != "1" ] && [ -f "$DISK" ]; then
  LSOF_OUT="$(mktemp)"
  lsof -t -- "$DISK" >"$LSOF_OUT" 2>/dev/null &
  LSOF_PID=$!
fi

# --- 編譯與簽章 (只在需要時; 用標記檔 .signed 記住「編譯過且簽過」, 比對用 shell 內建的 -nt, 不開新程序) ---
BIN="$ROOT/vz/.build/release/vz"
STAMP="$ROOT/vz/.build/.signed"
if [ "$OPT_DRY" != "1" ]; then
  need=0
  { [ -x "$BIN" ] && [ -f "$STAMP" ]; } || need=1
  [ "$BIN" -nt "$STAMP" ] && need=1                      # binary 被重編過 (簽章會消失)
  for f in "$ROOT"/vz/Package.swift "$ROOT"/vz/vz.entitlements "$ROOT"/vz/Sources/vz/*.swift; do
    [ "$f" -nt "$STAMP" ] && need=1
  done
  if [ "$need" = 1 ]; then
    echo "編譯 vz ..." >&2
    (cd "$ROOT/vz" && swift build -c release 2>&1 | grep -E 'error|warning: unre|Compiling|Build complete' >&2) || true
    [ -x "$BIN" ] || { echo "編譯失敗" >&2; exit 1; }
    # 沒有 com.apple.security.virtualization entitlement, VZ 會拒絕啟動
    codesign --force --sign - --entitlements "$ROOT/vz/vz.entitlements" "$BIN" >&2
    touch "$STAMP"
  fi
fi

# --- 磁碟 ---
if [ ! -f "$DISK" ]; then
  if [ "$MODE" = "install" ]; then
    if [ "$OPT_DRY" = "1" ]; then echo "(--dry-run: 會建立 $DISK_SIZE 稀疏磁碟 $DISK)" >&2; else truncate -s "$DISK_SIZE" "$DISK"; fi
  else
    echo "找不到磁碟 $OS/vz/$DISK; 第一次請用  ./vz.sh $OS install" >&2; exit 1
  fi
fi
if [ -n "$LSOF_PID" ]; then
  # raw 磁碟沒有檔案鎖: 任何程序 (qemu、vfkit、另一個 vz) 已開著就擋下, 避免毀掉檔案系統
  wait "$LSOF_PID" || true
  _p="$(cat "$LSOF_OUT")"; rm -f "$LSOF_OUT"
  if [ -n "$_p" ]; then echo "磁碟 $DISK 已被程序使用中 (pid: $(echo $_p)), 不啟動" >&2; exit 1; fi
fi
if [ "$MODE" = "install" ]; then
  [ -n "$INSTALL_ISO" ] && [ -f "$INSTALL_ISO" ] || { echo "找不到安裝光碟: ${INSTALL_ISO:-(INSTALL_ISO 未設定)}" >&2; exit 1; }
fi

ARGS=(--disk "$DISK" --cpus "$CPUS" --memory-mb "$MEMORY_MB")
[ -z "$MAC" ] || ARGS+=(--mac "$MAC")
[ "$OPT_MIC" != "1" ] || ARGS+=(--mic)
if [ "$OPT_GUI" = "1" ]; then ARGS+=(--gui --width "$XRES" --height "$YRES"); fi

# --- 開機: 預設直接載入 kernel; install / --efi / 沒有 kernel 資料夾就走 UEFI ---
DIRECT=0
if [ "$OPT_EFI" = "0" ] && [ -z "$MODE" ] && { [ -n "$KERNEL" ] || [ -d "$DIRECT_DIR" ]; }; then DIRECT=1; fi
if [ "$DIRECT" = "1" ]; then
  [ -n "$KERNEL" ] || { [ ! -f "$DIRECT_DIR/Image" ] || KERNEL="$DIRECT_DIR/Image"; }
  [ -n "$KERNEL" ] || { echo "找不到 kernel: 先跑  ./qemu.sh $OS extract  (或在 vz.conf 設 KERNEL)" >&2; exit 1; }
  if [ -z "$CMDLINE" ]; then
    if [ -f "$DIRECT_DIR/cmdline" ]; then CMDLINE="$(cat "$DIRECT_DIR/cmdline")"; else CMDLINE="ro"; fi
  fi
  if [ -z "$INITRD" ]; then
    # 沒有 initrd 就沒人解析 root=UUID=, 改用根分割 PARTUUID
    if [ -z "$ROOTDEV" ] && [ -f "$DIRECT_DIR/rootdev" ]; then ROOTDEV="$(cat "$DIRECT_DIR/rootdev")"; fi
    [ -n "$ROOTDEV" ] || { echo "需要根分割資訊: 重跑  ./qemu.sh $OS extract  (或在 vz.conf 設 ROOTDEV 或 INITRD)" >&2; exit 1; }
  fi
  # 開機參數的增刪修 (同 qemu.sh 的理由, 差別在主控台: VZ 的序列埠是 virtio console = hvc0)
  _cl=""
  set -f
  for _w in $CMDLINE; do
    case "$_w" in
      crashkernel=*|splash|quiet|vt.handoff*|\$*|console=*|ro|rw) ;;
      root=*) [ -z "$INITRD" ] || _cl="$_cl $_w" ;;
      *) _cl="$_cl $_w" ;;
    esac
  done
  set +f
  [ -n "$INITRD" ] || _cl=" root=$ROOTDEV rootwait rw$_cl"
  case " $_cl " in *" apparmor="*) ;; *) _cl="$_cl apparmor=0" ;; esac
  # 終端機大小與型號餵給 systemd, 免得它在序列埠上等回應
  _rows=24; _cols=80
  if _sz="$({ stty size </dev/tty; } 2>/dev/null)" && [ -n "$_sz" ]; then
    _r="${_sz% *}"; _c="${_sz#* }"
    case "$_r$_c" in *[!0-9]*|"") ;; *) if [ "$_r" -gt 0 ] && [ "$_c" -gt 0 ]; then _rows="$_r"; _cols="$_c"; fi ;; esac
  fi
  case "${TERM:-}" in
    xterm-256color|xterm|screen-256color|screen|tmux-256color|tmux|linux|vt220) _term="$TERM" ;;
    *) _term=xterm-256color ;;
  esac
  _con="systemd.tty.term.hvc0=$_term systemd.tty.rows.hvc0=$_rows systemd.tty.columns.hvc0=$_cols"
  if [ "$OPT_GUI" = "1" ]; then
    _con="console=hvc0 console=tty0 $_con systemd.unit=graphical.target"
  else
    _con="console=hvc0 $_con systemd.tty.term.console=$_term systemd.tty.rows.console=$_rows systemd.tty.columns.console=$_cols systemd.unit=multi-user.target"
  fi
  CMDLINE="${_cl# } sysctl.kernel.printk=4 $_con"
  if [ "$OPT_DRY" != "1" ]; then
    for f in "$KERNEL" ${INITRD:+"$INITRD"}; do [ -f "$f" ] || { echo "找不到 $f" >&2; exit 1; }; done
  fi
  ARGS+=(--kernel "$KERNEL" --cmdline "$CMDLINE")
  [ -z "$INITRD" ] || ARGS+=(--initrd "$INITRD")
else
  ARGS+=(--efi-vars "$VARS")
  if [ "$MODE" = "install" ]; then ARGS+=(--cdrom "$INSTALL_ISO"); [ "$OPT_GUI" = "1" ] || echo "警告: install 模式需要看畫面, 請加 --graphical" >&2; fi
fi

if [ "$OPT_SHARE" = "1" ]; then
  for entry in ${SHARES[@]+"${SHARES[@]}"}; do
    ARGS+=(--share "$entry"); echo "共享: ${entry%%:*}  (guest: sudo mount -t virtiofs ${entry%%:*} /mnt/${entry%%:*})" >&2
  done
fi
# 埠轉發 (Mac 127.0.0.1 -> VM): VZ 的 NAT 沒有內建, 由 vz 程式開 TCP 轉發器; 格式 "本機埠:VM埠", 需要 MAC
for rule in ${HOSTFWD[@]+"${HOSTFWD[@]}"}; do
  [ -n "$MAC" ] || { echo "HOSTFWD 需要 vz.conf 設定 MAC" >&2; exit 1; }
  ARGS+=(--forward "$rule")
done
[ -z "$MAC" ] || [ "$OPT_DRY" = "1" ] || echo "提示: 開機後用  ./vz.sh $OS ip  查 IP" >&2

if [ "$OPT_DRY" = "1" ]; then printf '%s\n' "$BIN" "${ARGS[@]}"; exit 0; fi
exec "$BIN" "${ARGS[@]}"
