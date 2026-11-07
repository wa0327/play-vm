#!/bin/bash
# Lima (vmType: vz) 啟動器
# 用法:  ./lima.sh <os> [模式]
#   <os>    OS 目錄名稱 (該目錄下要有 lima/lima.yaml), 例如 ubuntu
#   模式    (空)    建立 (若不存在) 並啟動, 然後進入 shell
#           ssh     以 X11 轉發連線 (tkinter 視窗顯示在 Mac 的 XQuartz)
#           stop    停止
#           delete  刪除 VM
#           ip      顯示 SSH 設定檔路徑
# VM 名稱 = <os>-lima
set -euo pipefail
cd "$(dirname "$0")"
OS="${1:-}"; MODE="${2:-}"
[ -n "$OS" ] || { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 1; }
OS="${OS%/}"; CONF="$OS/lima/lima.yaml"; NAME="$OS-lima"
[ -f "$CONF" ] || { echo "找不到 $CONF" >&2; exit 1; }
command -v limactl >/dev/null || { echo "請先 brew install lima" >&2; exit 1; }
SHARE="$PWD/share"; mkdir -p "$SHARE"
SET=(--set ".mounts[0].location = \"$SHARE\"")   # yaml 內是佔位值, 這裡帶入 repo 的 share/ 絕對路徑

case "$MODE" in
  "")     if limactl list -q | grep -qx "$NAME"; then
            # 已存在且停止時, 同步掛載路徑 (執行中的 VM 不能 edit, 要生效請先 stop 再啟動)
            [ "$(limactl list --format '{{.Status}}' "$NAME")" = "Running" ] || limactl edit --tty=false "${SET[@]}" "$NAME"
          else
            limactl create --name="$NAME" "${SET[@]}" "$CONF" --tty=false
          fi
          limactl start "$NAME"; exec limactl shell "$NAME" ;;
  ssh)    exec ssh -X -F "$HOME/.lima/$NAME/ssh.config" "lima-$NAME" ;;
  stop)   limactl stop "$NAME" ;;
  delete) limactl delete -f "$NAME" ;;
  ip)     echo "$HOME/.lima/$NAME/ssh.config" ;;
  *)      echo "未知模式: $MODE" >&2; exit 1 ;;
esac
