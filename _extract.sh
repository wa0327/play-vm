#!/bin/bash
# 從磁碟映像「離線」取出直接開機 (--direct) 要用的 kernel / initrd / 開機參數。不開機、不改動磁碟。
# 用法:  ./_extract.sh <qcow2|raw> <磁碟映像> <輸出資料夾> <主控台>
#   qcow2   qemu.sh 的磁碟: 先把根分割轉成暫存 raw (稀疏檔, 實際佔用約等於已用空間, 做完刪除) 才能讀
#   raw     vfkit.sh 的磁碟: 直接讀, 不用轉換、不佔暫存空間
#   主控台  寫進開機參數的 console=  (qemu 用 ttyAMA0, vfkit 用 hvc0)
# 輸出 (在輸出資料夾): Image (arm64 kernel)、initrd.img、cmdline (開機參數)、version (kernel 檔名)
# 通常由 qemu.sh / vfkit.sh 的 extract 模式呼叫, 不用直接執行。
# 做法: 解析 GPT -> 找到含 grub.cfg 的 ext4 分割 -> 用 debugfs 讀 grub.cfg 第一個 menuentry
#       -> 取出它指定的 kernel/initrd, 沿用 GRUB 的開機參數 (含正確的 root=UUID=...) -> _kernel.sh 解開 EFI 封裝。
# 限制: 只支援 GPT + ext4 (根分割在 LVM 或加密磁碟上不支援); 需要 debugfs: brew install e2fsprogs
# 注意: 磁碟被 VM 使用中 (vfkit 沒有檔案鎖) 讀到的內容可能不一致, 請先在 VM 裡關機。
set -euo pipefail
FORMAT="${1:-}"; DISK="${2:-}"; OUT="${3:-}"; CONSOLE="${4:-}"
[ -n "$CONSOLE" ] || { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 1; }
case "$FORMAT" in qcow2|raw) ;; *) echo "格式只能是 qcow2 或 raw (目前: $FORMAT)" >&2; exit 1 ;; esac
[ -f "$DISK" ] || { echo "找不到磁碟 $DISK" >&2; exit 1; }

DEBUGFS="$(command -v debugfs 2>/dev/null || true)"
[ -n "$DEBUGFS" ] || DEBUGFS=/opt/homebrew/opt/e2fsprogs/sbin/debugfs   # e2fsprogs 是 keg-only, 不在 PATH
[ -x "$DEBUGFS" ] || { echo "extract 需要 debugfs (離線讀 ext4): brew install e2fsprogs" >&2; exit 1; }
if [ "$FORMAT" = "qcow2" ]; then
  command -v qemu-img >/dev/null || { echo "找不到 qemu-img" >&2; exit 1; }
fi
case "$DISK" in *,*|*\?*) echo "磁碟路徑不能含逗號或問號: $DISK" >&2; exit 1 ;; esac
HERE="$(cd "$(dirname "$0")" && pwd)"

python3 -I - "$FORMAT" "$DISK" "$OUT" "$CONSOLE" "$DEBUGFS" "$HERE/_kernel.sh" <<'PYEOF'
import os, re, shutil, struct, subprocess, sys, tempfile, uuid
fmt, disk, outdir, console, debugfs, kernel_sh = sys.argv[1:7]
ESP = "c12a7328-f81f-11d2-ba4b-00a0c93ec93b"

def die(msg):
    sys.exit("extract: " + msg)

tmp = tempfile.mkdtemp(prefix="extract.")

def qcow2_to_raw(off, size, dst):    # 把 qcow2 內 [off, off+size) 這一段轉成 raw 檔 (稀疏)
    opts = "driver=raw,offset=%d,size=%d,file.driver=qcow2,file.file.driver=file,file.file.filename=%s" % (off, size, disk)
    r = subprocess.run(["qemu-img", "convert", "-S", "4k", "--image-opts", opts, "-O", "raw", dst], capture_output=True, text=True)
    if r.returncode:
        die("qemu-img 讀取失敗 (VM 還在執行嗎? 請先在 VM 裡關機): " + r.stderr.strip())

def read_bytes(off, size):           # 讀一小段 (分割表、檔案系統魔數)
    if fmt == "raw":
        with open(disk, "rb") as f:
            f.seek(off)
            return f.read(size)
    dst = os.path.join(tmp, "small.raw")
    qcow2_to_raw(off, size, dst)
    return open(dst, "rb").read()

try:
    d = read_bytes(0, 1 << 20)
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
        if read_bytes(off, 2048)[1080:1082] != b"\x53\xef":          # ext2/3/4 超級區塊魔數 0xEF53
            print("p%d: 不是 ext 檔案系統 (LVM/加密/其他), 略過" % num)
            continue
        if fmt == "raw":
            spec = "%s?offset=%d" % (disk, off)                      # debugfs 直接讀 raw 裡的這一段, 不用複製
            print("p%d: ext 檔案系統 %.1f GiB (raw 直接讀)" % (num, size / 2**30), flush=True)
        else:
            print("p%d: ext 檔案系統 %.1f GiB, 轉成暫存 raw (稀疏檔, 做完會刪除) ..." % (num, size / 2**30), flush=True)
            spec = os.path.join(tmp, "p%d.raw" % num)
            qcow2_to_raw(off, size, spec)

        def dbg(cmd, spec=spec):
            return subprocess.run([debugfs, "-R", cmd, spec], capture_output=True).stdout

        cfg = None
        for path in ("/boot/grub/grub.cfg", "/grub/grub.cfg"):      # 前者: /boot 在根分割; 後者: /boot 是獨立分割
            out = dbg("cat " + path)
            if b"menuentry" in out:
                cfg = out.decode(errors="replace")
                break
        if cfg is None:
            print("p%d: 找不到 grub.cfg, 略過" % num)
            continue
        found = (num, spec, cfg, dbg)
        break
    if not found:
        die("沒有找到含 grub.cfg 的 ext4 分割 (根分割在 LVM 或加密磁碟上時, 目前不支援)")
    num, spec, cfg, dbg = found

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
    want = "console=" + console
    if want not in keep:
        keep.insert(0, want)       # 放最前面: 有視窗時 console=tty0 仍是主要主控台, 無視窗時序列埠也看得到
    cmdline = " ".join(keep)

    for src, name in ((kpath, "vmlinuz"), (initrd, "initrd.img")):
        dst = os.path.join(tmp, name)
        subprocess.run([debugfs, "-R", "dump %s %s" % (src, dst), spec], capture_output=True)
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
        print("  %-11s %d bytes" % (name, os.path.getsize(os.path.join(outdir, name))))
    print("開機參數: " + cmdline)
finally:
    shutil.rmtree(tmp, ignore_errors=True)
PYEOF
