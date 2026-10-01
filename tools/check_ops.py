"""定向属性测试：把控制流指令的操作数逐个改坏，检查输出质量。

随机变异很难恰好改到某条 LOOP/JMP 指令的跳转偏移（要改中那 4 个字节、
而且其余部分仍能解析），所以这条路径单独测：

    对每一处控制流指令，把它的跳转偏移改成极端值，然后要求
    "要么 luac2c 明确拒绝（退出码非 0 并有说明），
      要么它接受，那生成的 C 就必须仍然能编译通过"。

修复前的表现是：接受、并生成一份控制流被悄悄改错的 C（或引用不存在的标签），
两种情况都不该出现。

用法: python check_ops.py
"""
import os
import struct
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.environ.get('L2C_EXE') or os.path.join(ROOT, 'luac2c.exe')
GCC = os.environ.get('GCC') or 'gcc'
TMP = os.path.join(ROOT, 'tools', '.scratch', 'ops')
INCLUDES = ['-I', os.path.join(ROOT, 'lua-5.5.1', 'src'),
            '-I', os.path.join(ROOT, 'lua5.5-include')]

# 指令布局 Op(7)|A(8)|k(1)|B(8)|C(8)：低 7 位是操作码
OPS = {'FORLOOP': 73, 'FORPREP': 74, 'TFORLOOP': 77, 'JMP': 56}


def build(name: str) -> bytes:
    src = os.path.join(ROOT, 'test', name + '.lua')
    dst = os.path.join(TMP, name + '.luac')
    subprocess.run([os.path.join(ROOT, 'luac.exe'), '-o', dst, src], check=True)
    return open(dst, 'rb').read()


def candidates(data: bytes):
    """所有操作数位可以被改坏的位置（可能是误报，交给后续判定）"""
    out = []
    for op, code in OPS.items():
        for i in range(0, len(data) - 4):
            ins = struct.unpack_from('<I', data, i)[0]
            if (ins & 0x7F) == code:
                out.append((op, i, ins))
    return out


def main() -> int:
    os.makedirs(TMP, exist_ok=True)
    bad_c = os.path.join(TMP, 'out.c')
    bad_o = os.path.join(TMP, 'out.o')
    cases = tried = rejected = accepted = broken = 0
    problems = []

    for name in ('test_loop', 'test_table', 'test_pcall'):
        data = build(name)
        for op, off, ins in candidates(data):
            tried += 1
            b = bytearray(data)
            # 极值 Bx：回跳目标变负、前跳目标越界
            struct.pack_into('<I', b, off, (ins & 0xFFFF) | (0xFFF0 << 16))
            path = os.path.join(TMP, 'bad.luac')
            open(path, 'wb').write(bytes(b))
            p = subprocess.run([EXE, path, '--seed', '3', '-o', bad_c],
                               capture_output=True)
            if p.returncode != 0:
                rejected += 1
                continue
            accepted += 1
            cases += 1
            c = subprocess.run([GCC, '-c', bad_c, '-o', bad_o] + INCLUDES +
                               ['-std=c99', '-w'], capture_output=True)
            if c.returncode != 0:
                broken += 1
                first = c.stderr.decode('utf-8', 'replace').strip().split('\n')[0]
                problems.append('%s %s +0x%X: %s' % (name, op, off, first[:100]))

    print('候选位置=%d 被拒=%d 接受=%d 其中编译失败=%d'
          % (tried, rejected, accepted, broken))
    for s in problems[:6]:
        print('  ' + s)
    return 1 if broken else 0


if __name__ == '__main__':
    sys.exit(main())
