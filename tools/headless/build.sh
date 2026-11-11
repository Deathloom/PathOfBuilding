#!/bin/sh
# Builds runtime/PoBHeadless.exe with mingw-w64 (Linux or MSYS2).
# Needs: x86_64-w64-mingw32-gcc and the LuaJIT 2.1 headers (lua.h, lauxlib.h, lualib.h, luaconf.h).
# Links directly against PoB's runtime/lua51.dll, so no import library is needed.
set -e
cd "$(dirname "$0")/../.."
LUA_INC="${LUA_INC:-/usr/include/luajit-2.1}"
x86_64-w64-mingw32-gcc -O2 -s -I"$LUA_INC" tools/headless/PoBHeadless.c runtime/lua51.dll -o runtime/PoBHeadless.exe
echo "Built runtime/PoBHeadless.exe"
