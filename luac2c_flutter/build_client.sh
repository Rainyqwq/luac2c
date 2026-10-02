#!/bin/bash
# 在本机沙箱里构建 Windows 客户端。
#
# 为什么不用 flutter_tools：它启动就探测 Android SDK（where.exe）与 Visual
# Studio（vswhere），这两个进程都被沙箱的管道句柄限制挡住
# （CreateFile failed 231）。bash / PowerShell 换着调都一样，等多久都不行。
#
# 为什么不能直接用 PATH 里的 cmake：MinGW 自带的 cmake 4.4 会和 VS 的模块
# 混用，configure 阶段报 "No preprocessor test for Renesas"。必须用 VS 自带的
# 那个（build/windows/x64/CMakeCache.txt 里记的也是它）。
#
# 坑：这台机器的 VS 装在 C:\environments\VS2022BuildTools，不在 Program Files，
# 所以要么设好 INCLUDE/LIB/PATH，要么先跑 vcvars64.bat。
#
# 坑：沙箱注入了 HTTP_PROXY 与 http_proxy 两个只差大小写的环境变量，.NET 的
# Hashtable 视为重复键，MSBuild 构造 ProcessStartInfo 时直接抛
# ArgumentException（MSB6001）。下面 unset 掉。
set -u

VS="C:/environments/VS2022BuildTools"
MSVC="$VS/VC/Tools/MSVC/14.44.35207"
SDK="C:/Program Files (x86)/Windows Kits/10"
SDKVER="10.0.26100.0"
VSCMAKE="$VS/Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin"

# 坑：沙箱注入了 http_proxy / HTTP_PROXY / https_proxy / HTTPS_PROXY 四个变量，
# 大小写各一份。.NET 的 Hashtable 不区分大小写，MSBuild 构造 ProcessStartInfo
# 时直接抛 ArgumentException（MSB6001 "已添加项"）。构建不需要代理，清掉。
# ⚠️ 只清这四个，别用通配 —— 会连带清掉 CODEBUDDY_* 那些沙箱自己要的变量。
unset http_proxy HTTP_PROXY https_proxy HTTPS_PROXY ftp_proxy FTP_PROXY
unset all_proxy ALL_PROXY no_proxy NO_PROXY

export PATH="$VSCMAKE:$MSVC/bin/Hostx64/x64:$SDK/bin/$SDKVER/x64:$PATH"
export INCLUDE="$MSVC/include;$SDK/Include/$SDKVER/ucrt;$SDK/Include/$SDKVER/um;$SDK/Include/$SDKVER/shared;$SDK/Include/$SDKVER/winrt"
export LIB="$MSVC/lib/x64;$SDK/Lib/$SDKVER/ucrt/x64;$SDK/Lib/$SDKVER/um/x64"

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build/windows/x64"

# Dart 侧（app.so）由 build 里的 flutter_assemble 规则生成，它自己调
# dart 前端，不需要 flutter_tools 在场。
"$VSCMAKE/cmake.exe" --build "$BUILD" --config Release --target INSTALL
rc=$?
echo "cmake_exit=$rc"
exit $rc
