#!/bin/bash
# 把 Ubuntu 的 vmlinuz (EFI zboot 封裝) 解成可直接開機的 arm64 Image (給 vfkit.sh / qemu.sh 的 --direct 用)
# 用法:  ./_kernel.sh <vmlinuz> [輸出檔]     輸出預設為 <vmlinuz 所在資料夾>/Image
# 取得 vmlinuz / initrd (VM 裡; /boot/vmlinuz-* 只有 root 能讀, 要先 sudo cp 出來):
#   sudo cp /boot/vmlinuz /tmp/vmlinuz && sudo cp /boot/initrd.img /tmp/initrd.img && sudo chmod 644 /tmp/vmlinuz /tmp/initrd.img
#   scp <使用者>@<VM>:/tmp/vmlinuz <使用者>@<VM>:/tmp/initrd.img <OS>/<工具>/
# 注意: VM 升級 kernel 後, 宿主端的 kernel/initrd 不會跟著更新, 要重新取出並重跑本工具。
# 需要 python3; 封裝內是 zstd 壓縮時另需 zstd (brew install zstd)。
set -euo pipefail
IN="${1:-}"
[ -f "$IN" ] || { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 1; }
OUT="${2:-$(dirname "$IN")/Image}"

python3 -I - "$IN" "$OUT" <<'EOF'
import gzip, struct, subprocess, sys

src, dst = sys.argv[1], sys.argv[2]
d = open(src, "rb").read()

def is_image(b):              # arm64 Image 的標頭: offset 56 是 "ARMd"
    return b[56:60] == b"ARMd"

def section(b, name):         # 從 PE 找區段 (systemd-stub 把 kernel 放在 .linux)
    pe = struct.unpack_from("<I", b, 0x3C)[0]
    nsec, = struct.unpack_from("<H", b, pe + 6)
    opt, = struct.unpack_from("<H", b, pe + 20)
    for i in range(nsec):
        n, vs, va, rs, ro = struct.unpack_from("<8sIIII", b, pe + 24 + opt + 40 * i)
        if n.rstrip(b"\0") == name:
            return b[ro:ro + rs]
    return None

def unzboot(z):               # EFI zboot: 標頭 "zimg", 之後是壓縮的 Image
    off, size = struct.unpack_from("<II", z, 8)
    comp = z[24:56].split(b"\0")[0].decode()
    payload = z[off:off + size]
    if comp == "gzip":
        return gzip.decompress(payload)
    if comp == "zstd":
        try:
            return subprocess.run(["zstd", "-d", "-c"], input=payload, check=True, capture_output=True).stdout
        except FileNotFoundError:
            sys.exit("封裝內是 zstd 壓縮, 請先 brew install zstd")
    sys.exit("不支援的壓縮格式: %s" % comp)

img = d
if not is_image(img) and img[:2] == b"MZ":
    inner = section(img, b".linux")
    if inner is not None:
        img = inner
    if img[4:8] == b"zimg":
        img = unzboot(img)
if not is_image(img):
    sys.exit("解開後不是 arm64 Image (標頭不是 ARMd): 這個檔案可能不是 arm64 的 kernel")
open(dst, "wb").write(img)
print("%s: %d bytes (arm64 Image)" % (dst, len(img)))
EOF
