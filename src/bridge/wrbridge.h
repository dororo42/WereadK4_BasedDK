/* wrbridge.h — LuaJIT 主进程与 C 设备层的桥（Lua 5.1 C API）。
 *
 * 为什么用 Lua C API 而非 FFI：主进程静态链接（BUILDMODE=static + -static），
 * 静态可执行文件没有动态符号表，LuaJIT FFI 的 ffi.C.<sym> 依赖 dlsym 无法解析。
 * Lua C API（lua_pushcfunction）在静态/动态链接下都成立，且后续切动态变体
 * （DK-2 复用多看 libcurl/OpenSSL）时无需重写本桥。
 */
#ifndef WR_BRIDGE_H
#define WR_BRIDGE_H

#include <lua.h>

/* 注册全局 "wr" 表（fb/input/font 全部入口）。返回 0 成功。 */
int  wr_register(lua_State *L);

/* 清理：恢复原屏 + 关闭 fb/input。可重复调用，正常退出路径使用。 */
void wr_cleanup(void);

/* 信号应急恢复：仅 async-signal-safe 操作（恢复原屏 + 释放输入独占），
 * 跳过 free/munmap/FT_Done。信号处理器专用，随后应立即 _exit()。 */
void wr_emergency_restore(void);

#endif
