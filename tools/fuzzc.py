"""luac2c 输出质量模糊测试：被接受的畸形输入，生成的 C 必须仍然能编译。

fuzz.py 只检查 luac2c 本身不崩；这个脚本往前一步 —— 只要 luac2c 返回 0，
就拿 gcc -fsyntax-only 编一遍它生成的 C。任何编译失败都说明校验有漏：
畸形字节码不该被翻译成一份语法错误的文件，而应该在 luac2c 里就被拒掉。

用法: python fuzzc.py [迭代次数]
"""
import os
import random
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# L2C_EXE 可以指向别的版本，用来做 A/B（例如确认某个校验确实堵住了旧缺陷）
EXE = os.environ.get('L2C_EXE') or os.path.join(ROOT, 'luac2c.exe')
GCC = os.environ.get('GCC') or 'gcc'
TMP = os.path.join(ROOT, 'tools', '.scratch', 'fuzzc')
OUT = os.path.join(TMP, 'out.c')
CRASH = 0x80000000

INCLUDES = ['-I', os.path.join(ROOT, 'lua-5.5.1', 'src'),
            '-I', os.path.join(ROOT, 'lua5.5-include')]


def build_bases() -> list:
    os.makedirs(TMP, exist_ok=True)
    bases = []
    for name in ('test_oop', 'test_loop', 'test_string', 'test_vararg', 'test_table'):
        src = os.path.join(ROOT, 'test', name + '.lua')
        dst = os.path.join(TMP, name + '.luac')
        subprocess.run([os.path.join(ROOT, 'luac.exe'), '-o', dst, src], check=True)
        bases.append(bytearray(open(dst, 'rb').read()))
    return bases


def mutate(data: bytearray, rnd: random.Random) -> bytearray:
    b = bytearray(data)
    kind = rnd.randrange(4)
    if kind == 0:                                   # 指令字段乱改（最容易造出越界操作数）
        for _ in range(rnd.randrange(1, 5)):
            i = rnd.randrange(len(b) - 4)
            b[i:i + 4] = bytes([rnd.randrange(256) for _ in range(4)])
    elif kind == 1:                                 # 位翻转
        for _ in range(rnd.randrange(1, 6)):
            i = rnd.randrange(len(b))
            b[i] ^= 1 << rnd.randrange(8)
    elif kind == 2:                                 # 把某几个位置改成 0xFF（拉大计数/下标）
        for _ in range(rnd.randrange(1, 4)):
            i = rnd.randrange(len(b))
            b[i] = 0xFF
    else:                                           # 随机插入长度字段的极值
        for _ in range(rnd.randrange(1, 3)):
            i = rnd.randrange(4, len(b) - 8)
            b[i:i + 4] = (0xFFFFFF if rnd.random() < 0.5 else 0x7FFFFFFF).to_bytes(4, 'little')
    return b


def main() -> int:
    iters = int(sys.argv[1]) if len(sys.argv) > 1 else 200
    rnd = random.Random(20260926)
    bases = build_bases()
    bad_path = os.path.join(TMP, 'bad.luac')
    rejected = translated = crashed = compile_fail = 0
    broken = []

    for it in range(iters):
        b = mutate(rnd.choice(bases), rnd)
        open(bad_path, 'wb').write(bytes(b))
        p = subprocess.run([EXE, bad_path, '--seed', '3', '-o', OUT],
                           capture_output=True)
        if p.returncode >= CRASH:
            crashed += 1
            broken.append((it, 'CRASH 0x%X' % p.returncode))
            continue
        if p.returncode != 0:
            rejected += 1
            continue
        translated += 1
        # 必须是完整编译：-fsyntax-only 不检查"用了但没定义的标签"，
        # 而那正是畸形跳转偏移会造成的问题。
        obj = os.path.join(TMP, 'out.o')
        c = subprocess.run([GCC, '-c', OUT, '-o', obj] + INCLUDES +
                           ['-std=c99', '-w'], capture_output=True)
        if c.returncode != 0:
            compile_fail += 1
            first = c.stderr.decode('utf-8', 'replace').strip().split('\n')[0]
            broken.append((it, first[:140]))
            open(os.path.join(TMP, 'fail_%d.luac' % it), 'wb').write(bytes(b))

    print('iterations=%d translated=%d rejected=%d crashed=%d compile_fail=%d'
          % (iters, translated, rejected, crashed, compile_fail))
    for it, msg in broken[:5]:
        print('  #%d %s' % (it, msg))
    return 0 if not broken else 1


if __name__ == '__main__':
    sys.exit(main())
