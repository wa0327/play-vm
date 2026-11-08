#!/bin/bash
# 開機計時 (host 端 server): 照常啟動 VM, 同時接收 guest 的 boot-ping 回報, 印出各里程碑在 host 時間軸上的時間。
# 用法:  ./boottime.sh <啟動指令...>      例如  ./boottime.sh ./qemu.sh ubuntu --graphical
#   啟動指令照常佔用這個終端機 (序列埠/monitor 不受影響); 回報到達時印在 stderr。結束碼同啟動指令。
# 前提: guest 裡裝了 guest/boot-ping.sh  (ssh <guest> 'sudo bash -s' < guest/boot-ping.sh)
# 時間的算法: 計時從執行啟動指令那一刻開始; guest 回報自己的 uptime 與里程碑 (從 kernel 啟動起算),
#   「kernel 啟動前」= 回報到達的 host 時間 - guest uptime (含啟動腳本、QEMU 啟動、載入 kernel), 里程碑 + 這段 = host 時間軸。
# 環境變數: BOOTTIME_PORT (預設 7777), BOOTTIME_BIND (預設 127.0.0.1; QEMU 使用者網路會把 guest 對 10.0.2.2 的連線轉到這裡)
set -euo pipefail
[ $# -gt 0 ] || { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 1; }
# 程式碼用 -c 傳入 (不用 stdin), 讓啟動指令繼承到的 stdin 仍是這個終端機
PY=$(cat <<'PYEOF'
import os, socket, subprocess, sys, threading, time
port = int(os.environ.get("BOOTTIME_PORT", "7777"))
bind = os.environ.get("BOOTTIME_BIND", "127.0.0.1")
ls = socket.socket()
ls.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    ls.bind((bind, port))
except OSError as e:
    sys.exit("boottime: 無法在 %s:%d 監聽 (%s)" % (bind, port, e))
ls.listen(4)

def out(s):
    # 啟動指令可能把終端機切成 raw 模式 (QEMU 的 -serial stdio), 所以用 \r\n 換行
    sys.stderr.write(s.replace("\n", "\r\n") + "\r\n"); sys.stderr.flush()

t0 = time.time()

def serve():
    while True:
        try:
            c, addr = ls.accept()
        except OSError:
            return
        arrive = time.time() - t0
        c.settimeout(3)
        try:
            msg = c.recv(65536).decode(errors="replace").strip()
        except OSError:
            msg = ""
        finally:
            c.close()
        d = {}
        for w in msg.split():
            k, _, v = w.partition("=")
            try: d[k] = float(v)
            except ValueError: pass
        if "uptime" not in d:
            out("boottime: 收到無法解析的回報: %r" % msg[:120]); continue
        pre = arrive - d.pop("uptime")
        lines = ["", "── 開機計時 (秒, host 時間軸; 從執行啟動指令起算) ──",
                 "  %-32s %6.2f" % ("kernel 啟動前 (腳本+QEMU+載入)", pre)]
        for k, v in sorted(((k, v) for k, v in d.items() if v > 0), key=lambda x: x[1]):
            lines.append("  %-32s %6.2f   (guest %.2f)" % (k, pre + v, v))
        never = [k for k, v in d.items() if v <= 0]
        if never: lines.append("  未達成/未啟用: " + " ".join(never))
        lines.append("  %-32s %6.2f" % ("回報到達", arrive))
        out("\n".join(lines))

threading.Thread(target=serve, daemon=True).start()
try:
    rc = subprocess.call(sys.argv[1:])
except FileNotFoundError:
    sys.exit("boottime: 找不到指令 %s" % sys.argv[1])
except KeyboardInterrupt:
    rc = 130
ls.close()
sys.exit(rc)
PYEOF
)
exec python3 -I -c "$PY" "$@"
