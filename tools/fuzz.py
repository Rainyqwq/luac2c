"""luac2c 畸形输入健壮性测试。

对一份合法 .luac 做随机变异（位翻转/截断/长度字段篡改），逐个喂给 luac2c，
要求：要么正常翻译（exit 0），要么给出清晰错误（exit 1）——绝不允许崩溃
（Windows 上崩溃表现为返回码 >= 0x80000000，如 0xC0000005 访问违规、
0xC00000FD 栈溢出）。

用法: python fuzz.py [迭代次数]
"""
import os
import random
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(ROOT, 'luac2c.exe')
TMP = os.path.join(ROOT, 'tools', '.scratch', 'fuzz')
BASE = os.path.join(TMP, 'base.luac')
OUT = os.path.join(TMP, 'out.c')
CRASH = 0x80000000

# 头部里各长度字段的偏移（0x1B 'Lua' ver fmt <6 字节 magic> 之后）
# 依次是 int / Instruction / lua_Integer / lua_Number 的 size 字节
HDR_SIZE_OFFSETS = (12,)


def build_base() -> None:
    os.makedirs(TMP, exist_ok=True)
    src = os.path.join(ROOT, 'test', 'test_oop.lua')
    subprocess.run([os.path.join(ROOT, 'luac.exe'), '-o', BASE, src], check=True)


def mutate(data: bytes, rnd: random.Random) -> bytes:
    b = bytearray(data)
    kind = rnd.randrange(6)
    if kind == 0:                                   # 随机位翻转
        for _ in range(rnd.randrange(1, 8)):
            i = rnd.randrange(len(b))
            b[i] ^= 1 << rnd.randrange(8)
    elif kind == 1:                                 # 截断
        b = b[: rnd.randrange(1, len(b))]
    elif kind == 2:                                 # 整块替换成随机字节
        i = rnd.randrange(len(b))
        b[i:i + 4] = bytes(rnd.randrange(256) for _ in range(4))
    elif kind == 3:                                 # 头部 size 字段改成荒谬值
        off = rnd.choice(HDR_SIZE_OFFSETS)
        b[off] = rnd.choice((0x00, 0x01, 0x7F, 0x80, 0xFF))
    elif kind == 4:                                 # 版本号 / 格式号篡改
        b[rnd.choice((4, 5))] = rnd.randrange(256)
    else:                                           # 大块长度字段塞极大 varint
        i = rnd.randrange(max(1, len(b) - 8))
        b[i:i + 5] = b'\xff\xff\xff\xff\x7f'
    return bytes(b)


def main() -> None:
    n = int(sys.argv[1]) if len(sys.argv) > 1 else 400
    build_base()
    with open(BASE, 'rb') as f:
        base = f.read()
    rnd = random.Random(20260919)
    ok = err = crash = 0
    crashes = []
    for k in range(n):
        data = mutate(base, rnd)
        case = os.path.join(TMP, 'case.luac')
        with open(case, 'wb') as f:
            f.write(data)
        try:
            r = subprocess.run([EXE, case, '-o', OUT],
                               capture_output=True, timeout=60)
            code = r.returncode
        except subprocess.TimeoutExpired:
            print(f'[{k}] TIMEOUT')
            crash += 1
            crashes.append(k)
            continue
        if code >= CRASH or code < 0:
            crash += 1
            crashes.append(k)
            print(f'[{k}] CRASH rc=0x{code & 0xFFFFFFFF:08X}')
            with open(os.path.join(TMP, f'crash_{k}.luac'), 'wb') as f:
                f.write(data)
        elif code == 0:
            ok += 1
        else:
            err += 1
            if not r.stderr.strip():
                print(f'[{k}] exit {code} but no message')
    print(f'iterations={n} translated={ok} rejected={err} crashed={crash}')
    if crashes:
        print('crashing cases:', crashes[:20])


if __name__ == '__main__':
    main()
