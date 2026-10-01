"""开关矩阵测试：每种命令行开关组合都要能编译**并正确运行**。

runall.sh 只跑默认 / --static / --seed N 三种模式，别的开关组合没人验证过，
于是"池为空时桩函数签名不一致"这种缺陷（--no-pool 必崩）能一直躺在里面。
这个脚本把组合一个个走完：生成 -> 编译 -> 运行 -> 与 lua.exe 输出逐字节比对。

用法: python check_combos.py [用例名...]      默认 test_string test_oop test_meta
"""
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.environ.get('L2C_EXE') or os.path.join(ROOT, 'luac2c.exe')
GCC = os.environ.get('GCC') or 'gcc'
TMP = os.path.join(ROOT, 'tools', '.scratch', 'combos')
INCLUDES = ['-I', os.path.join(ROOT, 'lua-5.5.1', 'src'),
            '-I', os.path.join(ROOT, 'lua5.5-include')]
LIB = os.path.join(ROOT, 'lua-5.5.1', 'build', 'liblua.a')

COMBOS = [
    [],
    ['--static'],
    ['--seed', '4'],
    ['--seed', '7'],
    ['--no-guard'],
    ['--no-opaque'],
    ['--no-mba'],
    ['--no-wipe'],
    ['--no-pool'],
    ['--pool-all'],
    ['--annotate'],
    ['--seed', '4', '--no-pool'],
    ['--no-guard', '--no-opaque', '--no-mba', '--no-wipe'],
    ['--static', '--no-pool'],
    ['--l2c-release'],
    ['--l2c-release', '--no-guard'],
]

# 优化级别也要走一遍：守卫里"页面可写即篡改"的误报就只在 -O1/-O2 下出现，
# 只测 -O0 永远看不到（客户端与文档都用 -O0，但 README 说的是"任意 C 编译器"）。
LEVELS = ['-O0', '-O2']


def main() -> int:
    os.makedirs(TMP, exist_ok=True)
    cases = sys.argv[1:] or ['test_string', 'test_oop', 'test_meta']
    fails = 0
    for case in cases:
        luac = os.path.join(ROOT, 'test', case + '.luac')
        ref = subprocess.run([os.path.join(ROOT, 'lua.exe'),
                              os.path.join(ROOT, 'test', case + '.lua')],
                             capture_output=True).stdout
        for combo in COMBOS:
            c = os.path.join(TMP, 'out.c')
            exe = os.path.join(TMP, 'out.exe')
            tag = ' '.join(combo) or '(默认)'
            gen = subprocess.run([EXE, luac, '-o', c] + combo, capture_output=True)
            if gen.returncode != 0:
                print('FAIL %s %s: luac2c exit %d %s'
                      % (case, tag, gen.returncode,
                         gen.stderr.decode('utf-8', 'replace').strip()[:80]))
                fails += 1
                continue
            for lvl in LEVELS:
                cc = subprocess.run([GCC, c, '-o', exe] + INCLUDES +
                                    ['-std=c99', lvl, '-w', LIB, '-lm'],
                                    capture_output=True)
                if cc.returncode != 0:
                    first = cc.stderr.decode('utf-8', 'replace').strip().split('\n')[0]
                    print('FAIL %s %s %s: 编译失败 %s' % (case, tag, lvl, first[:90]))
                    fails += 1
                    continue
                got = subprocess.run([exe], capture_output=True).stdout
                if got != ref:
                    print('FAIL %s %s %s: 运行输出不一致' % (case, tag, lvl))
                    fails += 1
    print('%d 个用例 x %d 种组合 x %d 个优化级别，失败 %d'
          % (len(cases), len(COMBOS), len(LEVELS), fails))
    return 1 if fails else 0


if __name__ == '__main__':
    sys.exit(main())
