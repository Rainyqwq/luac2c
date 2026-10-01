"""后链接签名的端到端检查：构建 -> 报 rva -> 签名 -> 篡改每个关键位置。

覆盖三处：签名区间内一个字节、水印槽、签名标志。三者都应让产物给出语义错误
（输出与原件不同或非零退出），原件本身必须正常。

用法: python signcheck.py [用例名]        默认 test_string
"""
import os
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GCC = os.environ.get('GCC') or 'gcc'
TMP = os.path.join(ROOT, 'tools', '.scratch', 'sign')
MAGIC = 0x3143534C          # 'LCS1'，签名槽的第一个魔数


def run(cmd):
    return subprocess.run(cmd, capture_output=True)


def main() -> int:
    case = sys.argv[1] if len(sys.argv) > 1 else 'test_string'
    os.makedirs(TMP, exist_ok=True)
    luac = os.path.join(ROOT, 'test', case + '.luac')
    lua = os.path.join(ROOT, 'test', case + '.lua')
    c = os.path.join(TMP, 'out.c')
    exe = os.path.join(TMP, 'out.exe')

    r = run([os.path.join(ROOT, 'luac2c.exe'), luac, '--fingerprint', '7',
             '--seed', '3', '-o', c])
    if r.returncode != 0:
        print('luac2c 失败:', r.stderr.decode('utf-8', 'replace')[:200])
        return 1
    r = run([GCC, c, '-I', os.path.join(ROOT, 'lua-5.5.1', 'src'),
             '-I', os.path.join(ROOT, 'lua5.5-include'), '-std=c99', '-w', '-O0',
             '-o', exe, os.path.join(ROOT, 'lua-5.5.1', 'build', 'liblua.a'), '-lm'])
    if r.returncode != 0:
        print('gcc 失败:', r.stderr.decode('utf-8', 'replace')[:300])
        return 1

    ref = run([exe])
    if ref.returncode != 0:
        print('未签名的产物就没跑通，先查这个')
        return 1

    sig = run([exe, '--l2c-sig']).stdout.decode('utf-8', 'replace')
    ra = rb = None
    for line in sig.split('\n'):
        if line.startswith('rva_a='):
            parts = line.split()
            ra = int(parts[0].split('=')[1], 16)
            rb = int(parts[1].split('=')[1], 16)
    if ra is None or rb is None or rb <= ra:
        print('拿不到受保护区 RVA:', sig[:200])
        return 1

    r = run([os.path.join(ROOT, 'luac2c.exe'), '--sign', exe,
             hex(ra), hex(rb)])
    if r.returncode != 0:
        print('签名失败:', r.stderr.decode('utf-8', 'replace')[:200])
        return 1
    print('已签名 span=0x%X..0x%X（%d 字节）' % (ra, rb, rb - ra))

    data = open(exe, 'rb').read()
    slot = data.find(struct.pack('<I', MAGIC))
    if slot < 0:
        print('产物里找不到签名槽')
        return 1

    spots = [('span 内 1 字节', ra), ('水印槽', slot + 24), ('签名标志', slot + 12),
             ('签名标志清零', slot + 12)]
    fails = 0
    for name, off in spots:
        out = os.path.join(TMP, 'tampered.exe')
        b = bytearray(data)
        if name == '签名标志清零':
            b[off] = 0                      # 1 -> 0：只靠 --require-sig 才能识破
        else:
            b[off] ^= 0x5A
        open(out, 'wb').write(bytes(b))
        r = run([out])
        bad = (r.returncode != 0) or (r.stdout != ref.stdout)
        if name == '签名标志清零':
            print('  %-14s 偏移 0x%-7X → exit=%-4d %s'
                  % (name, off, r.returncode, '（普通构建按"未签名"处理，需 --require-sig）'))
            continue
        print('  %-14s 偏移 0x%-7X → exit=%-4d %s'
              % (name, off, r.returncode, '已检出' if bad else '★ 未检出'))
        if not bad:
            fails += 1
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
