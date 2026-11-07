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
#           extract   從磁碟離線取出 kernel/initrd/開機參數, 存到 <os>/qemu/direct/ (給 --direct 用; 要先 brew install e2fsprogs; VM 要先關機)
# 選項:  --res 寬x高   解析度, 例如 --res 1440x900 (預設見 qemu.conf)
#        --zoom        縮放視窗         --mic       加麥克風 (macOS 會詢問權限)
#        --no-share    這次不共享資料夾   --tpm       啟用軟體 TPM (目前 HVF 下會當掉)
#        --headless    不開視窗 (ssh / X11 轉發用; 關機請在 VM 裡 sudo poweroff)
#        --direct      直接載入 kernel 開機, 略過 UEFI/GRUB (先跑一次 extract; 或在 qemu.conf 自行設 KERNEL/INITRD/CMDLINE)
#                      流程: ./qemu.sh <os> install  ->  ./qemu.sh <os> extract  ->  ./qemu.sh <os> --direct
#                      VM 裡升級 kernel 後要重跑 extract, 否則 --direct 還是開舊的 kernel
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
OPT_HEADLESS=0; OPT_ZOOM=off; OPT_MIC=0; OPT_SHARE=1; OPT_TPM=0; OPT_DRY=0; OPT_RES=""; OPT_DIRECT=0
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --headless) OPT_HEADLESS=1 ;;
    --zoom)     OPT_ZOOM=on ;;
    --mic)      OPT_MIC=1 ;;
    --no-share) OPT_SHARE=0 ;;
    --tpm)      OPT_TPM=1 ;;
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
KERNEL=""; INITRD=""; CMDLINE=""  # 只在 --direct 使用; 沒設定就用 $DIRECT_DIR 裡 extract 取出的 (qemu.conf 設了就以 conf 為準)

cd "$OS/qemu"
# shellcheck disable=SC1091
source ./qemu.conf
if [ -n "$OPT_RES" ]; then XRES="${OPT_RES%x*}"; YRES="${OPT_RES#*x}"; fi   # --res 優先於 qemu.conf

[ -n "$DISK" ] || { echo "$OS/qemu/qemu.conf 沒有設定 DISK" >&2; exit 1; }
# --- extract: 不開機, 直接從磁碟離線取出 kernel / initrd / 開機參數 (給 --direct 用) ---
# 做法: 解析 GPT -> 找到有 grub.cfg 的 ext4 分割 -> 轉成暫存 raw (稀疏檔, 實際佔用約等於該分割的已用空間, 做完刪除)
#       -> 用 debugfs 讀 grub.cfg 第一個 menuentry, 取出它指定的 kernel/initrd 與開機參數 -> kernel.sh 解開 EFI 封裝。
# 不改動磁碟; VM 還在跑時 qemu-img 取不到鎖會直接失敗 (正好當保護)。
if [ "$MODE" = "extract" ]; then
  DEBUGFS="$(command -v debugfs 2>/dev/null || true)"
  [ -n "$DEBUGFS" ] || DEBUGFS=/opt/homebrew/opt/e2fsprogs/sbin/debugfs   # e2fsprogs 是 keg-only, 不在 PATH
  [ -x "$DEBUGFS" ] || { echo "extract 需要 debugfs (離線讀 ext4): brew install e2fsprogs" >&2; exit 1; }
  command -v qemu-img >/dev/null || { echo "找不到 qemu-img" >&2; exit 1; }
  [ -f "$DISK" ] || { echo "找不到磁碟 $OS/qemu/$DISK; 第一次請先  ./qemu.sh $OS install" >&2; exit 1; }
  case "$PWD/$DISK" in *,*) echo "磁碟路徑含逗號, qemu-img 的 --image-opts 無法處理: $PWD/$DISK" >&2; exit 1 ;; esac
  python3 -I - "$PWD/$DISK" "$PWD/$DIRECT_DIR" "$DEBUGFS" "$ROOT/kernel.sh" <<'PYEOF'
import os, re, shutil, struct, subprocess, sys, tempfile, uuid
disk, outdir, debugfs, kernel_sh = sys.argv[1:5]
ESP = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

def die(msg):
    sys.exit("extract: " + msg)

def to_raw(off, size, dst):          # 把 qcow2 內 [off, off+size) 這一段轉成 raw 檔 (稀疏)
    opts = "driver=raw,offset=%d,size=%d,file.driver=qcow2,file.file.driver=file,file.file.filename=%s" % (off, size, disk)
    r = subprocess.run(["qemu-img", "convert", "-S", "4k", "--image-opts", opts, "-O", "raw", dst], capture_output=True, text=True)
    if r.returncode:
        die("qemu-img 讀取失敗 (VM 還在執行嗎? 請先在 VM 裡關機): " + r.stderr.strip())

tmp = tempfile.mkdtemp(prefix="qemu-extract.")
try:
    head = os.path.join(tmp, "head.raw")
    to_raw(0, 1 << 20, head)
    d = open(head, "rb").read()
    if d[512:520] != b"EFI PART":
        die("磁碟不是 GPT 分割表, 目前只支援 GPT (Ubuntu 的 UEFI 安裝預設就是)")
    lba = struct.unpack_from("<Q", d, 512 + 72)[0]
    n, sz = struct.unpack_from("<II", d, 512 + 80)
    parts = []
    for i in range(n):
        e = d[lba * 512 + i * sz: lba * 512 + (i + 1) * sz]
        if len(e) < 128 or e[:16] == b"\0" * 16:
            continue
        t = str(uuid.UUID(bytes_le=e[:16]))
        s, en = struct.unpack_from("<QQ", e, 32)
        parts.append((i + 1, t, s * 512, (en - s + 1) * 512))

    found = None
    for num, t, off, size in parts:
        if t == ESP:
            continue
        probe = os.path.join(tmp, "probe.raw")
        to_raw(off, 2048, probe)
        if open(probe, "rb").read()[1080:1082] != b"\x53\xef":      # ext2/3/4 超級區塊魔數 0xEF53
            print("p%d: 不是 ext 檔案系統 (LVM/加密/其他), 略過" % num)
            continue
        print("p%d: ext 檔案系統 %.1f GiB, 轉成暫存 raw (稀疏檔, 做完會刪除) ..." % (num, size / 2**30), flush=True)
        raw = os.path.join(tmp, "p%d.raw" % num)
        to_raw(off, size, raw)

        def dbg(cmd):
            return subprocess.run([debugfs, "-R", cmd, raw], capture_output=True).stdout

        cfg = None
        for path in ("/boot/grub/grub.cfg", "/grub/grub.cfg"):      # 前者: /boot 在根分割; 後者: /boot 是獨立分割
            out = dbg("cat " + path)
            if b"menuentry" in out:
                cfg = out.decode(errors="replace")
                break
        if cfg is None:
            os.remove(raw)
            print("p%d: 找不到 grub.cfg, 略過" % num)
            continue
        found = (num, raw, cfg, dbg)
        break
    if not found:
        die("沒有找到含 grub.cfg 的 ext4 分割 (根分割在 LVM 或加密磁碟上時, 目前不支援)")
    num, raw, cfg, dbg = found

    # 取第一個 menuentry (Ubuntu 預設開機項目) 的 linux / initrd 行; 遇到下一個 menuentry/submenu 就停
    linux = initrd = None
    in_entry = False
    for line in cfg.splitlines():
        s = line.strip()
        if s.startswith(("menuentry ", "submenu ")):
            if in_entry:
                break
            in_entry = s.startswith("menuentry ")
            continue
        if not in_entry:
            continue
        if linux is None and re.match(r"(linux|linux16|linuxefi)\s", s):
            linux = s.split(None, 1)[1]
        elif initrd is None and re.match(r"(initrd|initrdefi)\s", s):
            initrd = s.split(None, 1)[1].split()[0]
    if not linux or not initrd:
        die("grub.cfg 的第一個 menuentry 裡找不到 linux / initrd 行")
    kpath, _, kargs = linux.partition(" ")

    # 開機參數: 沿用 GRUB 的 (含正確的 root=UUID=...), 去掉直接開機用不到或會出問題的項目
    #   crashkernel=  含逗號 (vfkit 的 cmdline 以逗號分隔), 且 kdump 在這裡沒用
    #   splash / $vt_handoff / vt.handoff  是 GRUB 的圖形開機畫面用的 (變數在直接開機時不會展開)
    keep = [t for t in kargs.split()
            if not (t.startswith("crashkernel=") or t.startswith("vt.handoff") or t == "splash" or t.startswith("$"))]
    if "console=ttyAMA0" not in keep:
        keep.insert(0, "console=ttyAMA0")      # 放最前面: 有視窗時 console=tty0 仍是主要主控台, 無視窗時序列埠也看得到
    cmdline = " ".join(keep)

    for src, name in ((kpath, "vmlinuz"), (initrd, "initrd.img")):
        dst = os.path.join(tmp, name)
        subprocess.run([debugfs, "-R", "dump %s %s" % (src, dst), raw], capture_output=True)
        if not os.path.exists(dst) or os.path.getsize(dst) == 0:
            die("從磁碟取不出 %s" % src)
    r = subprocess.run([kernel_sh, os.path.join(tmp, "vmlinuz"), os.path.join(tmp, "Image")], capture_output=True, text=True)
    if r.returncode:
        die("解開 kernel 失敗: " + (r.stderr.strip() or r.stdout.strip()))

    os.makedirs(outdir, exist_ok=True)
    for name in ("Image", "initrd.img"):
        shutil.move(os.path.join(tmp, name), os.path.join(outdir, name))
    open(os.path.join(outdir, "cmdline"), "w").write(cmdline + "\n")
    open(os.path.join(outdir, "version"), "w").write(os.path.basename(kpath) + "\n")
    print()
    print("已取出 (來自 p%d 的 %s):" % (num, os.path.basename(kpath)))
    for name in ("Image", "initrd.img", "cmdline"):
        print("  %-11s %s" % (name, "%d bytes" % os.path.getsize(os.path.join(outdir, name))))
    print("開機參數: " + cmdline)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PYEOF
  echo "下一步: ./qemu.sh $OS --direct   (VM 裡升級 kernel 後要重跑  ./qemu.sh $OS extract)"
  exit 0
fi

[ -n "$VARS" ] || VARS="vars.fd"
if [ "$OPT_DIRECT" = "1" ]; then
  [ "$MODE" != "install" ] || { echo "--direct 不能搭配 install (安裝要走 UEFI 才能從光碟開機)" >&2; exit 1; }
  # qemu.conf 沒設定的項目, 用 extract 取出的檔案補上
  if [ -z "$KERNEL" ] && [ -f "$DIRECT_DIR/Image" ]; then KERNEL="$DIRECT_DIR/Image"; fi
  if [ -z "$INITRD" ] && [ -f "$DIRECT_DIR/initrd.img" ]; then INITRD="$DIRECT_DIR/initrd.img"; fi
  if [ -z "$CMDLINE" ]; then
    if [ -f "$DIRECT_DIR/cmdline" ]; then CMDLINE="$(cat "$DIRECT_DIR/cmdline")"; else CMDLINE="console=ttyAMA0 quiet"; fi
  fi
  [ -n "$KERNEL" ] && [ -n "$INITRD" ] || { echo "--direct 找不到 kernel/initrd: 先跑  ./qemu.sh $OS extract  (或在 $OS/qemu/qemu.conf 設定 KERNEL 和 INITRD)" >&2; exit 1; }
  if [ "$OPT_DRY" != "1" ]; then
    for f in "$KERNEL" "$INITRD"; do [ -f "$f" ] || { echo "找不到 $f" >&2; exit 1; }; done
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

# --- 開機方式: 預設 UEFI (pflash); --direct 直接載入 kernel ---
BOOT_ARGS=(
  -drive if=pflash,format=raw,unit=0,file="$FW_CODE",readonly=on
  -drive if=pflash,format=raw,unit=1,file="$VARS"
)
if [ "$OPT_DIRECT" = "1" ]; then
  BOOT_ARGS=(-kernel "$KERNEL" -initrd "$INITRD" -append "$CMDLINE")
  # 無視窗時把終端機接上序列埠 (kernel 要有 console=ttyAMA0), 否則看不到任何開機訊息
  if [ "$OPT_HEADLESS" = "1" ]; then BOOT_ARGS+=(-serial mon:stdio); fi
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
