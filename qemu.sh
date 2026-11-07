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
# 選項:  --res 寬x高   解析度, 例如 --res 1440x900 (預設見 qemu.conf)
#        --zoom        縮放視窗         --mic       加麥克風 (macOS 會詢問權限)
#        --no-share    這次不共享資料夾   --tpm       啟用軟體 TPM (目前 HVF 下會當掉)
#        --headless    不開視窗 (ssh / X11 轉發用; 關機請在 VM 裡 sudo poweroff)
#        --dry-run     只印出 QEMU 參數, 不啟動                   -h, --help  顯示說明
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
OPT_HEADLESS=0; OPT_ZOOM=off; OPT_MIC=0; OPT_SHARE=1; OPT_TPM=0; OPT_DRY=0; OPT_RES=""
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --headless) OPT_HEADLESS=1 ;;
    --zoom)     OPT_ZOOM=on ;;
    --mic)      OPT_MIC=1 ;;
    --no-share) OPT_SHARE=0 ;;
    --tpm)      OPT_TPM=1 ;;
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
[ -f "$OS/qemu/qemu.conf" ] || { echo "找不到 $OS/qemu/qemu.conf" >&2; usage; }
case "$MODE" in ""|install|drivers|net|safe|bochs) ;; *) echo "未知模式: $MODE" >&2; usage ;; esac

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

cd "$OS/qemu"
# shellcheck disable=SC1091
source ./qemu.conf
if [ -n "$OPT_RES" ]; then XRES="${OPT_RES%x*}"; YRES="${OPT_RES#*x}"; fi   # --res 優先於 qemu.conf

[ -n "$DISK" ] || { echo "$OS/qemu/qemu.conf 沒有設定 DISK" >&2; exit 1; }
[ -n "$VARS" ] || VARS="vars.fd"
if [ ! -f "$VARS" ]; then cp "$FW_VARS_TEMPLATE" "$VARS"; fi

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
# HEADLESS=1: 不開視窗、不加顯示卡 (X11 轉發 / ssh 用; 關機請在 VM 裡 sudo poweroff, 或在這個終端機按 Ctrl+C = 斷電)
DISPLAY_ARG="cocoa,zoom-to-fit=$OPT_ZOOM"
if [ "$OPT_HEADLESS" = "1" ]; then GPU_ARGS=(); DISPLAY_ARG="none"; fi

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

QEMU=(qemu-system-aarch64)
if [ "$OPT_DRY" = "1" ]; then QEMU=(printf '%s\n'); fi

"${QEMU[@]}" \
  -name "$NAME" \
  -machine virt,highmem=on \
  -accel hvf \
  -cpu host \
  -smp "$CPUS" \
  -m "$RAM" \
  -drive if=pflash,format=raw,unit=0,file="$FW_CODE",readonly=on \
  -drive if=pflash,format=raw,unit=1,file="$VARS" \
  ${TPM_ARGS[@]+"${TPM_ARGS[@]}"} \
  ${GPU_ARGS[@]+"${GPU_ARGS[@]}"} \
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
