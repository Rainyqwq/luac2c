"""构造一个"函数嵌套 N 层"的 .luac，用来验证 luac2c 的递归深度限制。

这种文件 luac 永远生成不出来（Lua 解析器自己先报错），但攻击者可以手工拼出来；
解析器的递归若没有上限，就是一次栈溢出。

用法: python mkdeep.py <层数> <输出文件>
"""
import struct
import sys


def varint(x: int) -> bytes:
    """Lua 5.5 的 varint: 高位在前，每字节 7 位，最高位为续行标志。"""
    if x == 0:
        return b'\x00'
    parts = []
    while x:
        parts.append(x & 0x7F)
        x >>= 7
    out = bytearray()
    for i in range(len(parts) - 1, -1, -1):
        b = parts[i]
        if i:
            b |= 0x80
        out.append(b)
    return bytes(out)


def header() -> bytes:
    """0x1B 'Lua' ver fmt <magic> 之后是 4 组 (size, 样本值)。"""
    out = bytearray(b'\x1bLua')
    out += bytes([0x55, 0x00])                        # version 5.5, format 0
    out += b'\x19\x93\r\n\x1a\n'
    out += bytes([4]) + struct.pack('<i', -0x5678)    # int          (LUAC_INT)
    out += bytes([4]) + struct.pack('<I', 0x12345678) # Instruction  (LUAC_INST)
    out += bytes([8]) + struct.pack('<q', -0x5678)    # lua_Integer
    out += bytes([8]) + struct.pack('<d', -370.5)     # lua_Number   (LUAC_NUM)
    return bytes(out)


def proto_head(has_child: int, off: int) -> bytes:
    """函数头：固定字段 + 空代码 + 空常量表 + 空上值表 + 子函数个数。

    loadCode 读完 n 之后会做一次 4 字节对齐（padding 从流里吃掉），所以这里
    必须跟着补 padding，否则解析器会错位。
    """
    out = bytearray()
    out += varint(0) + varint(0)          # linedefined / lastlinedefined
    out += bytes([0, 0, 2])               # numparams / flag / maxstack
    out += varint(0)                      # ncode
    while (off + len(out)) % 4:           # r_align(sizeof(Instruction))
        out += b'\x00'
    out += varint(0)                      # nconstants
    out += varint(0)                      # nupvalues
    out += varint(1 if has_child else 0)  # sizep
    return bytes(out)


def proto_tail() -> bytes:
    """函数尾：source(NULL) + 空调试信息（lineinfo/abslineinfo/locvars/upvalnames）。"""
    out = bytearray()
    out += varint(0) + varint(0)          # source: size 0 -> index 0 -> NULL
    out += varint(0) * 4                  # 四段调试信息全为空
    return bytes(out)


def main() -> None:
    depth = int(sys.argv[1]) if len(sys.argv) > 1 else 100000
    path = sys.argv[2] if len(sys.argv) > 2 else 'deep.luac'
    data = bytearray(header())
    data += bytes([0])                    # main closure 的上值个数
    for i in range(depth + 1):
        # 函数头是嵌套的：第 i 层的 sizep 之后紧跟着第 i+1 层的内容
        data += proto_head(i < depth, len(data))
    for _ in range(depth + 1):
        data += proto_tail()              # 由内向外逐层收尾
    with open(path, 'wb') as f:
        f.write(bytes(data))
    print(f'wrote {path}: depth={depth} bytes={len(data)}')


if __name__ == '__main__':
    main()
