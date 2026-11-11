/*
 * PoBHeadless.exe - tiny console host for running Path of Building scripts
 * without the GUI (Deathloom fork).
 *
 * It links against PoB's own runtime\lua51.dll (the same LuaJIT build the GUI
 * uses), so scripts behave exactly as in Path of Building.exe.
 *
 * Usage (from PoB's src folder):  ..\runtime\PoBHeadless.exe ImpactServer.lua [args]
 *
 * package.path / package.cpath are pointed at the runtime folder next to the
 * exe, so dkjson, xml, lua-utf8.dll etc. are found.
 *
 * Build: see build.sh (mingw-w64, links directly against runtime\lua51.dll).
 */
#include <stdio.h>
#include <string.h>
#include <windows.h>
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

static void push_paths(lua_State *L, const char *exeDir)
{
	char buf[4 * MAX_PATH + 256];
	lua_getglobal(L, "package");
	snprintf(buf, sizeof(buf), "%s\\lua\\?.lua;%s\\lua\\?\\init.lua;.\\?.lua", exeDir, exeDir);
	lua_pushstring(L, buf);
	lua_setfield(L, -2, "path");
	snprintf(buf, sizeof(buf), "%s\\?.dll;.\\?.dll", exeDir);
	lua_pushstring(L, buf);
	lua_setfield(L, -2, "cpath");
	lua_pop(L, 1);
}

int main(int argc, char **argv)
{
	char exeDir[MAX_PATH];
	DWORD n;
	char *slash;
	lua_State *L;
	int i;

	if (argc < 2) {
		fprintf(stderr, "Usage: PoBHeadless.exe <script.lua> [args...]\n");
		return 2;
	}
	n = GetModuleFileNameA(NULL, exeDir, MAX_PATH);
	if (n == 0 || n >= MAX_PATH) {
		fprintf(stderr, "Can't find exe folder\n");
		return 1;
	}
	slash = strrchr(exeDir, '\\');
	if (slash) *slash = '\0';

	L = luaL_newstate();
	if (!L) {
		fprintf(stderr, "Can't create Lua state\n");
		return 1;
	}
	luaL_openlibs(L);
	push_paths(L, exeDir);

	/* global arg table, like the stand-alone interpreter */
	lua_newtable(L);
	for (i = 1; i < argc; i++) {
		lua_pushstring(L, argv[i]);
		lua_rawseti(L, -2, i - 1);
	}
	lua_setglobal(L, "arg");

	if (luaL_dofile(L, argv[1]) != 0) {
		fprintf(stderr, "%s\n", lua_tostring(L, -1));
		lua_close(L);
		return 1;
	}
	lua_close(L);
	return 0;
}
