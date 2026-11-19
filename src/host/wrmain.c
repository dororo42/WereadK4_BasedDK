/* wrmain.c — DK-1 LuaJIT 主进程宿主（替换 fbtest 入口 main.c）。
 *
 * 职责：建 VM -> 开标准库 -> 注册 wr 桥 -> 跑 Lua 脚本 -> 清理（恢复原屏）。
 * 信号处理保证 Ctrl+C / kill 时也恢复原屏（与 fbtest 同款回滚安全）。
 * 用法：weread <script.lua> [--smoke]
 *   --smoke 置全局 SMOKE=true，脚本渲染一帧即退出（自动化验收用，不进按键循环）。
 */
#include <lua.h>
#include <lualib.h>
#include <lauxlib.h>

#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#include "wrbridge.h"

static void on_signal(int sig)
{
    /* 异步信号安全：wr_emergency_restore 只做 memcpy/ioctl/fsync/close 级恢复，
     * 不碰 free/munmap/FT_Done（非 async-signal-safe，打断 malloc 会死锁/坏堆）。
     * fd 与映射由 _exit 回收。 */
    wr_emergency_restore();
    _exit(128 + sig);
}

int main(int argc, char **argv)
{
    lua_State *L;
    const char *script = NULL;
    int smoke = 0;
    int i, rc;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--smoke") == 0) smoke = 1;
        else if (!script) script = argv[i];
    }
    if (!script) {
        fprintf(stderr, "usage: %s <script.lua> [--smoke]\n", argv[0]);
        return 2;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    L = luaL_newstate();
    if (!L) { fprintf(stderr, "luaL_newstate failed\n"); return 1; }
    luaL_openlibs(L);
    wr_register(L);
    lua_pushboolean(L, smoke);
    lua_setglobal(L, "SMOKE");

    /* 全局 arg 表：arg[0]=script，arg[1..]=其余参数（标准 Lua 语义） */
    lua_newtable(L);
    lua_pushstring(L, script);
    lua_rawseti(L, -2, 0);
    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--smoke") == 0) continue;
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");

    rc = luaL_dofile(L, script);
    if (rc != 0) {
        fprintf(stderr, "lua error: %s\n", lua_tostring(L, -1));
        wr_cleanup();
        lua_close(L);
        return 1;
    }

    wr_cleanup();
    lua_close(L);
    return 0;
}
