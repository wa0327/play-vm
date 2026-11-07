#!/bin/bash
# krunkit (libkrun) 啟動器 — 重點是 virtio-gpu 的 3D 加速 (Venus/Vulkan, 經 MoltenVK 轉 Metal)
# 用法:  ./krunkit.sh <os> [選項]
#   <os>  OS 目錄名稱 (該目錄下要有 krunkit/krunkit.conf), 例如 ubuntu
# 注意: krunkit 沒有視窗; 用 ssh 進 VM (要圖形程式請 ssh -X + XQuartz, 或改用 qemu.sh)
# 選項:  --res 寬x高   virtio-gpu 解析度     --dry-run  只印參數
#        -h, --help    顯示說明
# 網路用 gvproxy (使用者空間 NAT): 主機 ssh -p <SSH_PORT> <user>@127.0.0.1
# 驗證 3D (VM 內):  sudo apt install vulkan-tools mesa-vulkan-drivers && vulkaninfo --summary
#   看到 "Venus" 或 "Virtio-GPU Venus" 就表示 Vulkan 加速生效。
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

usage() {
  sed -n '2,/^set -euo/p' "$ROOT/krunkit.sh" | sed '$d' | sed 's/^# \{0,1\}//' >&2
  exit "${1:-1}"
}

OPT_DRY=0; OPT_RES=""; POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  OPT_DRY=1 ;;
    --res)      shift; OPT_RES="${1:-}" ;;
    --res=*)    OPT_RES="${1#--res=}" ;;
    -h|--help)  usage 0 ;;
    -*)         echo "未知選項: $1" >&2; usage ;;
    *)          POS+=("$1") ;;
  esac
  shift
done
if [ -n "$OPT_RES" ] && ! [[ "$OPT_RES" =~ ^[0-9]+x[0-9]+$ ]]; then echo "--res 格式要像 1920x1200" >&2; exit 1; fi
OS="${POS[0]:-}"; [ -n "$OS" ] || usage
OS="${OS%/}"
[ -f "$OS/krunkit/krunkit.conf" ] || { echo "找不到 $OS/krunkit/krunkit.conf" >&2; usage; }

NAME="$OS"; DISK=disk.img; VARS=vars.fd; CPUS=4; MEMORY_MB=4096
XRES=1280; YRES=800; MAC=""; SSH_PORT=""
cd "$OS/krunkit"
# shellcheck disable=SC1091
source ./krunkit.conf
if [ -n "$OPT_RES" ]; then XRES="${OPT_RES%x*}"; YRES="${OPT_RES#*x}"; fi
[ -f "$DISK" ] || { echo "找不到磁碟 $OS/krunkit/$DISK" >&2; exit 1; }

PIDFILE=krunkit.pid; NETSOCK=net.sock; GVSOCK=gvproxy.sock
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "$NAME 已經在執行 (pid $(cat "$PIDFILE"))" >&2; exit 1
fi

NET="virtio-net,type=unixgram,path=$PWD/$NETSOCK"
[ -n "$MAC" ] && NET="$NET,mac=$MAC"
ARGS=(
  --cpus "$CPUS" --memory "$MEMORY_MB"
  --bootloader "efi,variable-store=$VARS,create"
  --device "virtio-blk,path=$DISK"
  --device "$NET"
  --device virtio-rng
  --pidfile "$PIDFILE"
)
# krunkit 沒有圖形視窗 (--gui 會被忽略); virtio-gpu 只提供 VM 內的 GPU (Venus/Vulkan)
ARGS+=(--device "virtio-gpu,width=$XRES,height=$YRES")

if [ "$OPT_DRY" = "1" ]; then printf '%s\n' gvproxy krunkit "${ARGS[@]}"; exit 0; fi

rm -f "$NETSOCK" "$GVSOCK"
GV=(gvproxy -listen-vfkit "unixgram://$PWD/$NETSOCK" -listen "unix://$PWD/$GVSOCK")
[ -n "$SSH_PORT" ] && GV+=(-ssh-port "$SSH_PORT")
"${GV[@]}" >/dev/null 2>&1 &
GVPID=$!
trap 'kill $GVPID 2>/dev/null || true; rm -f -- "$PIDFILE" "$NETSOCK" "$GVSOCK"' EXIT
for _ in 1 2 3 4 5; do [ -S "$NETSOCK" ] && break; sleep 1; done
[ -n "$SSH_PORT" ] && echo "提示: 開機後  ssh -p $SSH_PORT <user>@127.0.0.1" >&2
krunkit "${ARGS[@]}"
