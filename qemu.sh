#!/bin/bash
# QEMU (Apple Silicon, HVF) 啟動器
# 用法:  ./qemu.sh <os> [模式] [選項]
#   <os>    OS 目錄名稱 (該目錄下要有 qemu.conf), 例如 windows、ubuntu
#   模式    (空)      正常開機
#           install   第一次安裝 (掛載安裝光碟 INSTALL_ISO, 有 DRIVERS_ISO 也一併掛上)
#           drivers   正常開機 + 驅動光碟 + 額外一張 virtio-gpu (安裝顯示驅動用)
#           net       正常開機 + 驅動光碟 (補裝/重裝 virtio 驅動)
#           safe      用 ramfb 顯示 (畫面全黑時的退路)
#           bochs     實驗: bochs-display
#           extract   從磁碟離線取出 kernel/initrd/開機參數, 存到 <os>/qemu/direct/ (直接開機用; 要先 brew install e2fsprogs; VM 要先關機)
# 選項:  --res 寬x高   解析度, 例如 --res 1440x900 (預設見 qemu.conf)
#        --zoom        縮放視窗         --mic       加麥克風 (macOS 會詢問權限)
#        --no-share    這次不共享資料夾   --tpm       啟用軟體 TPM (目前 HVF 下會當掉)
#        --display     開視窗 (-display cocoa) 並加顯示卡 (virtio-gpu); guest 的 tty0/tty1 顯示在視窗
#                      不加 --display 就沒有視窗。序列埠 (guest 的 ttyAMA0) 一律接到這個終端機 (-serial mon:stdio), 在這裡登入;
#                      Ctrl-A c 切到 QEMU monitor, Ctrl-A x 結束 (在 guest 按 Ctrl-C 不會殺掉 VM)
#        --no-direct   強制走 UEFI/GRUB 開機。預設是直接載入 kernel (略過 UEFI/GRUB, 也不用 initrd), 條件: 有 <os>/qemu/direct/ 資料夾
#                      (只限一般開機, 不加模式)。資料夾由 extract 產生; 也可在 qemu.conf 自行設 KERNEL/ROOTDEV, 開機參數的底設 CMDLINE, 要用 initrd 就設 INITRD
#                      流程: ./qemu.sh <os> install  ->  ./qemu.sh <os> extract  ->  ./qemu.sh <os>
#                      VM 裡升級 kernel 後要重跑 extract, 否則還是開舊的 kernel
#        --dry-run    只印出 QEMU 參數, 不啟動                   -h, --help  顯示說明
# 各 OS 的差異放在 <os>/qemu/qemu.conf, 路徑相對於 <os>/qemu/ (共用的安裝光碟在上一層 ../)。
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

usage() {
  sed -n '2,/^set -euo/p' "$ROOT/qemu.sh" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  echo "可用的 OS:" >&2
  for c in "$ROOT"/*/qemu/qemu.conf; do [ -f "$c" ] && echo "  $(basename "$(dirname "$(dirname "$c")")")" >&2; done
  exit "${1:-1}"
}

# --- 參數解析 (選項可放在任何位置; 第一個非選項是 <os>, 第二個是 [模式]) ---
OPT_DISPLAY=0; OPT_ZOOM=off; OPT_MIC=0; OPT_SHARE=1; OPT_TPM=0; OPT_DRY=0; OPT_RES=""; OPT_DIRECT=0; OPT_NODIRECT=0
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --display)  OPT_DISPLAY=1 ;;
    --gui)      echo "--gui 已改名為 --display" >&2; exit 1 ;;
    --tty)      echo "--tty 已移除: 序列埠預設就接到這個終端機" >&2; exit 1 ;;
    --headless) echo "--headless 已移除: 不加 --display 就是無視窗, 序列埠預設就接到這個終端機" >&2; exit 1 ;;
    --zoom)     OPT_ZOOM=on ;;
    --mic)      OPT_MIC=1 ;;
    --no-share) OPT_SHARE=0 ;;
    --tpm)      OPT_TPM=1 ;;
    --dry-run)  OPT_DRY=1 ;;
    --direct)   echo "--direct 已移除: 有 direct/ 資料夾就預設直接開機 (先跑 extract); 要走 UEFI/GRUB 請加 --no-direct" >&2; exit 1 ;;
    --no-direct) OPT_NODIRECT=1 ;;
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
[ -f "$OS/qemu/qemu.conf" ] || { echo "找不到 $OS/qemu/qemu.conf" >&2; usage; }
case "$MODE" in ""|install|drivers|net|safe|bochs|extract) ;; *) echo "未知模式: $MODE" >&2; usage ;; esac

# --- 預設值 (qemu.conf 可覆蓋) ---
NAME="$OS"
DISK=""; DISK_BUS=virtio-blk; DISK_OPTS=",discard=unmap"   # discard=unmap: 客體 TRIM 會真的還空間給 Mac (conf 設 DISK_OPTS="" 可關閉)
VARS=""
INSTALL_ISO=""; DRIVERS_ISO=""
RAM=4G; CPUS=4
XRES=1920; YRES=1200
RAMFB_MODES=""
SHARES=()
HOSTFWD=()
FW_CODE=/opt/homebrew/share/qemu/edk2-aarch64-code.fd
FW_VARS_TEMPLATE=/opt/homebrew/share/qemu/edk2-arm-vars.fd
TPM_DIR=tpm
DIRECT_DIR=direct                 # extract 的輸出資料夾 (相對於 <os>/qemu/): Image、initrd.img、cmdline
KERNEL=""; INITRD=""; ROOTDEV=""; CMDLINE=""  # 只在直接開機使用; 沒設定就用 $DIRECT_DIR 裡 extract 取出的 (CMDLINE 是開機參數的底, console= 由腳本附加)

cd "$OS/qemu"
# shellcheck disable=SC1091
source ./qemu.conf
if [ -n "$OPT_RES" ]; then XRES="${OPT_RES%x*}"; YRES="${OPT_RES#*x}"; fi   # --res 優先於 qemu.conf

[ -n "$DISK" ] || { echo "$OS/qemu/qemu.conf 沒有設定 DISK" >&2; exit 1; }
# 直接開機 (略過 UEFI/GRUB) 是預設: 有 extract 的輸出資料夾 ($DIRECT_DIR) 就直接載入 kernel。
# 只限一般開機 (沒有 install/drivers/... 模式); --no-direct 強制走 UEFI/GRUB。
if [ "$OPT_NODIRECT" = "0" ] && [ -z "$MODE" ] && [ -d "$DIRECT_DIR" ]; then
  OPT_DIRECT=1
  echo "提示: 找到 $OS/qemu/$DIRECT_DIR/, 直接載入 kernel 開機 (要走 UEFI/GRUB 請加 --no-direct)" >&2
fi
# --- extract: 不開機, 直接從磁碟離線取出 kernel / initrd / 開機參數 (直接開機用) ---
# 實作在共用的 _extract.sh (vfkit.sh 也用它); 這裡的磁碟是 qcow2。
if [ "$MODE" = "extract" ]; then
  [ -f "$DISK" ] || { echo "找不到磁碟 $OS/qemu/$DISK; 第一次請先  ./qemu.sh $OS install" >&2; exit 1; }
  "$ROOT/_extract.sh" qcow2 "$PWD/$DISK" "$PWD/$DIRECT_DIR"
  echo "下一步: ./qemu.sh $OS   (VM 裡升級 kernel 後要重跑  ./qemu.sh $OS extract)"
  exit 0
fi

[ -n "$VARS" ] || VARS="vars.fd"
if [ "$OPT_DIRECT" = "1" ]; then
  # qemu.conf 沒設定的項目, 用 extract 取出的檔案補上
  if [ -z "$KERNEL" ] && [ -f "$DIRECT_DIR/Image" ]; then KERNEL="$DIRECT_DIR/Image"; fi
  # 開機參數的底: qemu.conf 的 CMDLINE, 沒設就用 extract 取出的原始值 (GRUB 那行, 一個字都沒改)
  if [ -z "$CMDLINE" ]; then
    if [ -f "$DIRECT_DIR/cmdline" ]; then CMDLINE="$(cat "$DIRECT_DIR/cmdline")"; else CMDLINE="ro"; fi
  fi
  [ -n "$KERNEL" ] || { echo "直接開機找不到 kernel: 先跑  ./qemu.sh $OS extract  (或在 $OS/qemu/qemu.conf 設定 KERNEL; 要走 UEFI/GRUB 請加 --no-direct)" >&2; exit 1; }
  # 預設不用 initrd (kernel 內建 virtio-blk/ext4, 掛根分割不需要它; 省約 1.3 秒); qemu.conf 設了 INITRD 才會載入
  USE_INITRD=0; [ -z "$INITRD" ] || USE_INITRD=1
  if [ "$USE_INITRD" = "0" ]; then
    [ "$DISK_BUS" = "virtio-blk" ] || { echo "直接開機不用 initrd 只支援 virtio-blk (nvme 驅動是模組); 請在 qemu.conf 設定 INITRD" >&2; exit 1; }
    # 沒有 initrd 就沒人解析 root=UUID=, 改用根分割的 PARTUUID (qemu.conf 可設 ROOTDEV 蓋掉; 預設是 extract 取出的 direct/rootdev)
    if [ -z "$ROOTDEV" ] && [ -f "$DIRECT_DIR/rootdev" ]; then ROOTDEV="$(cat "$DIRECT_DIR/rootdev")"; fi
    [ -n "$ROOTDEV" ] || { echo "直接開機不用 initrd 需要根分割資訊: 先(重新)跑  ./qemu.sh $OS extract  (或在 qemu.conf 設定 ROOTDEV 或 INITRD)" >&2; exit 1; }
  fi
  # 把開機參數的底 (GRUB 原始值) 依這次的開機方式增刪修:
  #   刪: crashkernel= (kdump 在這沒用)、splash / quiet / vt.handoff / $變數 (GRUB 圖形開機畫面用, 直接開機不會展開; quiet 下面重附)、console= (下面重附)
  #   改: 沒有 initrd 時 root= 換成根分割 PARTUUID + rootwait (沒人解析 UUID)
  #   加: console= 與終端機參數 (QEMU virt 的名稱固定: ttyAMA0 = PL011 序列埠, tty0 = kernel VT)。
  #       kernel 訊息會印到所有 console=; 最後一個才是 /dev/console (systemd 狀態行、緊急 shell 只送到它)。
  #         預設 (無視窗):  console=ttyAMA0            -> 序列埠, 在這個終端機
  #         --display:     console=ttyAMA0 console=tty0 -> /dev/console 是視窗, 序列埠上仍有 kernel 訊息和登入
  #       為什麼要明確給終端機型號與大小: 序列埠上的 systemd 沒被告知時會「問終端機」(XTGETTCAP 查型號、DSR 查大小),
  #       每次最多等 333 毫秒; 序列埠沒有人回答 (或回答很慢) 就白等 (實測 PID 1 一次 + 各服務的大小查詢, 共約 0.7 秒)。
  #       console=tty0 時 /dev/console 是 VT, systemd 直接知道是 linux, 不用問。
  _cl=""
  set -f                      # 下面用不加引號的 $CMDLINE 拆字, 關掉萬用字元展開避免 * ? [ 被當檔名
  for _w in $CMDLINE; do
    case "$_w" in
      crashkernel=*|splash|quiet|vt.handoff*|\$*|console=*) ;;
      root=*) [ "$USE_INITRD" = "1" ] && _cl="$_cl $_w" ;;
      *) _cl="$_cl $_w" ;;
    esac
  done
  set +f
  [ "$USE_INITRD" = "1" ] || _cl=" root=$ROOTDEV rootwait$_cl"
  _con="console=ttyAMA0"; [ "$OPT_DISPLAY" != "1" ] || _con="console=ttyAMA0 console=tty0"
  # 序列埠接的是這個終端機: 量它的大小、型號餵給 systemd (只在啟動當下量一次; 取不到 (不是終端機) 就用 24x80 / xterm-256color)
  _rows=24; _cols=80
  if _sz="$({ stty size </dev/tty; } 2>/dev/null)" && [ -n "$_sz" ]; then
    _r="${_sz% *}"; _c="${_sz#* }"
    case "$_r$_c" in *[!0-9]*|"") ;; *) if [ "$_r" -gt 0 ] && [ "$_c" -gt 0 ]; then _rows="$_r"; _cols="$_c"; fi ;; esac
  fi
  case "${TERM:-}" in
    xterm-256color|xterm|screen-256color|screen|tmux-256color|tmux|linux|vt220) _term="$TERM" ;;
    *) _term=xterm-256color ;;       # guest 不一定有 host 這個型號的 terminfo
  esac
  # 序列埠的 getty (ttyAMA0) 一定要給; /dev/console 也是序列埠時 (沒有 --display) 還要給 console 的
  _con="$_con systemd.tty.term.ttyAMA0=$_term systemd.tty.rows.ttyAMA0=$_rows systemd.tty.columns.ttyAMA0=$_cols"
  if [ "$OPT_DISPLAY" != "1" ]; then
    _con="$_con systemd.tty.term.console=$_term systemd.tty.rows.console=$_rows systemd.tty.columns.console=$_cols"
  fi
  CMDLINE="${_cl# } quiet $_con"     # quiet: kernel 只印警告以上, systemd 不印 [  OK  ] 狀態行 (少輸出到 console)
  if [ "$OPT_DRY" != "1" ]; then
    for f in "$KERNEL" ${INITRD:+"$INITRD"}; do [ -f "$f" ] || { echo "找不到 $f" >&2; exit 1; }; done
  fi
elif [ ! -f "$VARS" ]; then
  cp "$FW_VARS_TEMPLATE" "$VARS"     # 直接開機不用 UEFI, 所以不建立 vars.fd
fi

if [ "$MODE" = "install" ]; then
  [ -n "$INSTALL_ISO" ] && [ -f "$INSTALL_ISO" ] || { echo "找不到安裝光碟: ${INSTALL_ISO:-(INSTALL_ISO 未設定)}" >&2; exit 1; }
fi
if [ "$MODE" = "drivers" ] || [ "$MODE" = "net" ]; then
  [ -n "$DRIVERS_ISO" ] && [ -f "$DRIVERS_ISO" ] || { echo "$OS 沒有設定 DRIVERS_ISO 或檔案不存在" >&2; exit 1; }
fi

# --- 軟體 TPM 2.0 (選用) ---
# 目前 QEMU 11.1.3 在 macOS HVF 下加 tpm-tis-device 會 HV_BAD_ARGUMENT 當掉, 所以預設關閉;
# Windows 安裝時需用登錄檔繞過 TPM 檢查。日後 QEMU 修好可用 USE_TPM=1 啟用。
TPM_ARGS=()
if [ "$OPT_TPM" = "1" ]; then
  mkdir -p "$TPM_DIR"
  SOCK="$TPM_DIR/swtpm-sock-$$"
  swtpm socket --tpm2 \
    --tpmstate dir="$TPM_DIR" \
    --ctrl type=unixio,path="$SOCK" \
    --log file="$TPM_DIR/swtpm.log" \
    --flags not-need-init,startup-clear &
  SWTPM_PID=$!
  trap 'kill $SWTPM_PID 2>/dev/null || true' EXIT
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -S "$SOCK" ] && break; sleep 0.3; done
  TPM_ARGS+=(
    -chardev socket,id=chrtpm,path="$SOCK"
    -tpmdev  emulator,id=tpm0,chardev=chrtpm
    -device  tpm-tis-device,tpmdev=tpm0
  )
fi

# --- 顯示卡 ---
# 預設 virtio-gpu; RAMFB_MODES 列出的模式改用 ramfb (沒有驅動也能顯示)
GPU_ARGS=(-device virtio-gpu-pci,xres="$XRES",yres="$YRES")
if [ -n "$MODE" ]; then
  case " $RAMFB_MODES " in *" $MODE "*) GPU_ARGS=(-device ramfb) ;; esac
fi
if [ "$MODE" = "bochs" ]; then GPU_ARGS=(-device bochs-display); fi
# --display: 開視窗 (cocoa) 並加顯示卡; 沒給就不開視窗、不加顯示卡 (-display 只決定畫面顯示在哪, 顯示卡由 -device 決定)
DISPLAY_ARG="cocoa,zoom-to-fit=$OPT_ZOOM"
if [ "$OPT_DISPLAY" != "1" ]; then GPU_ARGS=(); DISPLAY_ARG="none"; fi
# 序列埠一律接到這個終端機: -serial mon:stdio (monitor 疊在同一條線上, Ctrl-A c 切換; 不用純 stdio, 因為純 stdio 時在 guest 按 Ctrl-C 會殺掉整台 VM)
SERIAL_ARGS=(-serial mon:stdio)
# 這些模式需要看畫面 (安裝/裝驅動/救援顯示), 沒給 --display 就會是看不到畫面的 VM
case "$MODE" in install|drivers|net|safe|bochs)
  [ "$OPT_DISPLAY" = "1" ] || echo "警告: $MODE 模式需要看畫面, 請加 --display" >&2 ;;
esac

# --- 共享資料夾 (SMB, 只在這次啟動有效) ---
# 腳本啟動一個只綁 127.0.0.1 的 Samba, 透過 QEMU guestfwd 給 VM; VM 關閉就一併關掉, Mac 上不留任何設定。
# Windows 內: 檔案總管網址列輸入 \\10.0.2.100\<名稱>  (或 net use Z: \\10.0.2.100\<名稱> /persistent:no)
# 清單 SHARES 寫在 qemu.conf, 格式 "名稱:路徑:模式"  模式 ro=唯讀 rw=可寫。
SMBD=/opt/homebrew/sbin/samba-dot-org-smbd
SMB_PORT=4450
NETDEV="user,id=net0"
if [ "$OPT_SHARE" = "1" ] && [ -x "$SMBD" ] && [ "${#SHARES[@]}" -gt 0 ]; then
  SMB_TMP="$(mktemp -d "${TMPDIR:-/tmp}/qemu-smb.XXXXXX")"
  mkdir -p "$SMB_TMP/ncalrpc"
  cat > "$SMB_TMP/smb.conf" <<EOF
[global]
private dir=$SMB_TMP
pid directory=$SMB_TMP
lock directory=$SMB_TMP
state directory=$SMB_TMP
cache directory=$SMB_TMP
ncalrpc dir=$SMB_TMP/ncalrpc
log file=$SMB_TMP/log.smbd
log level=2
smb passwd file=$SMB_TMP/smbpasswd
interfaces=127.0.0.1
bind interfaces only=yes
smb ports=$SMB_PORT
security=user
map to guest=Bad User
load printers=no
printing=bsd
disable spoolss=yes
usershare max shares=0
EOF
  SHARE_COUNT=0
  for entry in "${SHARES[@]}"; do
    s_name="${entry%%:*}"; s_rest="${entry#*:}"; s_path="${s_rest%:*}"; s_mode="${s_rest##*:}"
    if [ ! -d "$s_path" ]; then echo "略過共享 $s_name: 資料夾不存在 ($s_path)"; continue; fi
    s_ro=yes; [ "$s_mode" = "rw" ] && s_ro=no
    cat >> "$SMB_TMP/smb.conf" <<EOF
[$s_name]
path=$s_path
read only=$s_ro
guest ok=yes
force user=$(id -un)
nt acl support=no
vfs mkdir use tmp name=no
create mask=0644
directory mask=0755
force create mode=0644
force directory mode=0755
EOF
    echo "共享: \\\\10.0.2.100\\$s_name  <-  $s_path  ($([ "$s_ro" = yes ] && echo 唯讀 || echo 可寫), 只在本次啟動有效)"
    SHARE_COUNT=$((SHARE_COUNT + 1))
  done
  if [ "$SHARE_COUNT" -gt 0 ]; then
    "$SMBD" -F -s "$SMB_TMP/smb.conf" -l "$SMB_TMP" >"$SMB_TMP/smbd.out" 2>&1 &
    SMBD_PID=$!
    trap 'kill $SMBD_PID ${SWTPM_PID:-} 2>/dev/null || true' EXIT
    # 等 Samba 真的開始監聽 (最多約 15 秒)
    SMB_READY=0
    for _ in $(seq 1 30); do
      if nc -z 127.0.0.1 "$SMB_PORT" 2>/dev/null; then SMB_READY=1; break; fi
      kill -0 "$SMBD_PID" 2>/dev/null || break   # Samba 已經死掉就不用等了
      sleep 0.5
    done
    if [ "$SMB_READY" = "1" ]; then
      # 用 cmd: 讓「每一個」guest 連線各自開一條到 Samba 的連線
      # (tcp: 形式只會連線一次, SMB 客戶端反覆開關連線就會壞掉)
      NETDEV="user,id=net0,guestfwd=tcp:10.0.2.100:445-cmd:/usr/bin/nc 127.0.0.1 $SMB_PORT"
    else
      echo "警告: Samba 沒有成功啟動, 這次不提供共享 (詳見 $SMB_TMP/smbd.out)"
      kill "$SMBD_PID" 2>/dev/null || true
    fi
  fi
fi

# --- 埠轉發 (Mac -> VM) ---
# 使用者模式網路下 Mac 不能主動連進 VM; 在 qemu.conf 用 HOSTFWD 開洞, 格式 "tcp:主機位址:主機埠-:VM埠",
# 例如 HOSTFWD=("tcp:127.0.0.1:2222-:22")  之後  ssh -p 2222 localhost
# 建議只綁 127.0.0.1 (只有本機能連)。本機埠已被占用時略過該條規則, VM 仍照常啟動。
for rule in ${HOSTFWD[@]+"${HOSTFWD[@]}"}; do
  h="${rule%%-*}"; hport="${h##*:}"; gport="${rule#*-}"
  if [ "$OPT_DRY" != "1" ] && lsof -nP -iTCP:"$hport" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "略過轉發 $rule: 本機埠 $hport 已被占用" >&2; continue
  fi
  NETDEV="$NETDEV,hostfwd=$rule"
  echo "轉發: ${h#*:} -> VM ${gport#:}" >&2
done

# --- 音效: Intel HD Audio + macOS CoreAudio (預設只有輸出; MIC=1 才加麥克風) ---
AUDIO_ARGS=(-audiodev coreaudio,id=snd0 -device ich9-intel-hda)
if [ "$OPT_MIC" = "1" ]; then
  AUDIO_ARGS+=(-device hda-duplex,audiodev=snd0)
else
  AUDIO_ARGS+=(-device hda-output,audiodev=snd0)
fi

# --- 光碟 ---
CD_ARGS=()
if [ "$MODE" = "drivers" ]; then
  CD_ARGS+=(
    -drive  if=none,id=cd1,media=cdrom,readonly=on,file="$DRIVERS_ISO"
    -device usb-storage,drive=cd1
    -device virtio-gpu-pci,xres="$XRES",yres="$YRES"
  )
fi
if [ "$MODE" = "net" ]; then
  CD_ARGS+=(
    -drive  if=none,id=cd1,media=cdrom,readonly=on,file="$DRIVERS_ISO"
    -device usb-storage,drive=cd1
  )
fi
if [ "$MODE" = "install" ]; then
  CD_ARGS+=(
    -drive  if=none,id=cd0,media=cdrom,readonly=on,file="$INSTALL_ISO"
    -device usb-storage,drive=cd0,bootindex=1
  )
  if [ -n "$DRIVERS_ISO" ]; then
    CD_ARGS+=(
      -drive  if=none,id=cd1,media=cdrom,readonly=on,file="$DRIVERS_ISO"
      -device usb-storage,drive=cd1
    )
  fi
fi

# --- 磁碟 ---
if [ "$DISK_BUS" = "nvme" ]; then
  DISK_DEV="nvme,drive=hd0,serial=${NAME}disk,bootindex=2"
else
  DISK_DEV="virtio-blk-pci,drive=hd0,bootindex=2"
fi

# --- 開機方式: 有 direct/ 資料夾預設直接載入 kernel; --no-direct 或沒有資料夾就走 UEFI (pflash) ---
BOOT_ARGS=(
  -drive if=pflash,format=raw,unit=0,file="$FW_CODE",readonly=on
  -drive if=pflash,format=raw,unit=1,file="$VARS"
)
if [ "$OPT_DIRECT" = "1" ]; then
  BOOT_ARGS=(-kernel "$KERNEL" ${INITRD:+-initrd "$INITRD"} -append "$CMDLINE")
fi

QEMU=(qemu-system-aarch64)
if [ "$OPT_DRY" = "1" ]; then QEMU=(printf '%s\n'); fi

"${QEMU[@]}" \
  -name "$NAME" \
  -machine virt,highmem=on \
  -accel hvf \
  -cpu host \
  -smp "$CPUS" \
  -m "$RAM" \
  "${BOOT_ARGS[@]}" \
  ${TPM_ARGS[@]+"${TPM_ARGS[@]}"} \
  ${GPU_ARGS[@]+"${GPU_ARGS[@]}"} \
  ${SERIAL_ARGS[@]+"${SERIAL_ARGS[@]}"} \
  -device qemu-xhci \
  -device usb-kbd \
  -device usb-tablet \
  -drive if=none,id=hd0,format=qcow2,file="$DISK$DISK_OPTS" \
  -device "$DISK_DEV" \
  -netdev "$NETDEV" \
  -device virtio-net-pci,netdev=net0 \
  ${AUDIO_ARGS[@]+"${AUDIO_ARGS[@]}"} \
  ${CD_ARGS[@]+"${CD_ARGS[@]}"} \
  -display "$DISPLAY_ARG"
