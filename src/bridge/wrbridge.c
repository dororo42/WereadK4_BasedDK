/* wrbridge.c — LuaJIT <-> C 设备层桥（Lua 5.1 C API）。
 *
 * 单进程多看模式：本文件持有唯一的 fb 与 input 实例（全局），
 * Lua 侧通过 "wr" 表调用。fb_open 自动备份原屏，wr_cleanup 恢复——
 * 与 fbtest 同款回滚安全策略（铁律：设备操作先备份）。
 */
#include "wrbridge.h"

#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "fb.h"
#include "input.h"
#include "font8x16.h"
#include "render.h"
#include "net.h"

static struct wr_fb    g_fb;
static int             g_fb_open;
static uint8_t        *g_backup;
static size_t          g_backup_cap;
static struct wr_input g_in;
static int             g_in_open;

/* ---- fb ---- */

static int l_fb_open(lua_State *L)
{
    if (g_fb_open) { lua_pushboolean(L, 1); return 1; }
    if (wr_fb_open(&g_fb, "/dev/fb0") != 0) {
        lua_pushnil(L); lua_pushstring(L, "wr_fb_open(/dev/fb0) failed"); return 2;
    }
    g_backup_cap = wr_fb_visible_bytes(&g_fb);
    g_backup = (uint8_t *)malloc(g_backup_cap);
    if (g_backup)
        wr_fb_backup(&g_fb, g_backup, g_backup_cap);  /* 备份失败不致命，仅失去恢复能力 */
    g_fb_open = 1;
    lua_pushboolean(L, 1);
    return 1;
}

static int l_fb_close(lua_State *L)
{
    (void)L;
    wr_cleanup();
    return 0;
}

static int l_fb_w(lua_State *L) { lua_pushinteger(L, g_fb_open ? (lua_Integer)g_fb.xres : 0); return 1; }
static int l_fb_h(lua_State *L) { lua_pushinteger(L, g_fb_open ? (lua_Integer)g_fb.yres : 0); return 1; }

static int l_fb_refresh(lua_State *L)
{
    int fx = (int)luaL_optinteger(L, 1, WR_FX_PARTIAL);
    if (!g_fb_open) { lua_pushnil(L); lua_pushstring(L, "fb not open"); return 2; }
    int rc = wr_fb_refresh_full(&g_fb, fx);
    if (rc == 0) rc = wr_fb_wait(&g_fb);
    lua_pushboolean(L, rc == 0);
    return 1;
}

static int l_fb_fill(lua_State *L)
{
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    int w = (int)luaL_checkinteger(L, 3);
    int h = (int)luaL_checkinteger(L, 4);
    int gray = (int)luaL_optinteger(L, 5, 0);
    if (!g_fb_open) return 0;
    wr_fb_fill_rect(&g_fb, x, y, w, h, (uint8_t)gray);
    return 0;
}

/* fb_text(x, y, str [, scale=1 [, fg=0]]) -> 结束 x 坐标。
 * 8x16 点阵，每像素放大为 scale×scale 方块；fg 为灰度（0=黑,255=白），背景透明。 */
static int l_fb_text(lua_State *L)
{
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    const char *s = luaL_checkstring(L, 3);
    int scale = (int)luaL_optinteger(L, 4, 1);
    int fg = (int)luaL_optinteger(L, 5, 0);
    const char *p;
    int cx = x;

    if (!g_fb_open || scale < 1) { lua_pushinteger(L, x); return 1; }

    for (p = s; *p; p++) {
        unsigned char c = (unsigned char)*p;
        int row, col;
        if (c < WR_FONT_FIRST || c > WR_FONT_LAST) { cx += WR_FONT_W * scale; continue; }
        const uint8_t *g = wr_font8x16[c - WR_FONT_FIRST];
        for (row = 0; row < WR_FONT_H; row++) {
            uint8_t bits = g[row];
            if (!bits) continue;
            for (col = 0; col < WR_FONT_W; col++) {
                if (bits & (0x80 >> col))
                    wr_fb_fill_rect(&g_fb, cx + col * scale, y + row * scale,
                                    scale, scale, (uint8_t)fg);
            }
        }
        cx += WR_FONT_W * scale;
    }
    lua_pushinteger(L, cx);
    return 1;
}

static int l_fb_quant(lua_State *L)
{
    if (g_fb_open) wr_fb_quant(&g_fb);
    (void)L;
    return 0;
}

/* fb_get(x, y) -> 0..255 当前像素灰度（SMOKE 自检用）。 */
static int l_fb_get(lua_State *L)
{
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    if (!g_fb_open || x < 0 || y < 0 ||
        x >= (int)g_fb.xres || y >= (int)g_fb.yres) { lua_pushinteger(L, -1); return 1; }
    lua_pushinteger(L, g_fb.mem[(size_t)y * g_fb.line_length + x]);
    return 1;
}

/* ---- font（freetype，DK-1 step2 中文渲染） ---- */

static int l_font_load(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    int px = (int)luaL_optinteger(L, 2, 28);
    int id = wr_ft_load(path, px);
    if (id < 0) {
        lua_pushnil(L);
        lua_pushfstring(L, "font_load(%s) failed: %d", path, id);
        return 2;
    }
    lua_pushinteger(L, id);
    return 1;
}

static int l_font_close(lua_State *L)
{
    wr_ft_unload((int)luaL_checkinteger(L, 1));
    return 0;
}

/* fb_text_ft(id, x, y, utf8 [, fg=0]) -> 结束 x | nil, err。y 为行顶。 */
static int l_fb_text_ft(lua_State *L)
{
    int id = (int)luaL_checkinteger(L, 1);
    int x = (int)luaL_checkinteger(L, 2);
    int y = (int)luaL_checkinteger(L, 3);
    const char *s = luaL_checkstring(L, 4);
    int fg = (int)luaL_optinteger(L, 5, 0);
    int endx;

    if (!g_fb_open) { lua_pushnil(L); lua_pushstring(L, "fb not open"); return 2; }
    endx = wr_ft_draw(&g_fb, id, x, y, s, (uint8_t)fg);
    if (endx < 0) {
        lua_pushnil(L);
        lua_pushfstring(L, "fb_text_ft failed: %d", endx);
        return 2;
    }
    lua_pushinteger(L, endx);
    return 1;
}

/* font_width(id, utf8) -> px 宽度 | nil, err */
static int l_font_width(lua_State *L)
{
    int id = (int)luaL_checkinteger(L, 1);
    const char *s = luaL_checkstring(L, 2);
    int w = wr_ft_width(id, s);
    if (w < 0) {
        lua_pushnil(L);
        lua_pushfstring(L, "font_width failed: %d", w);
        return 2;
    }
    lua_pushinteger(L, w);
    return 1;
}

/* ---- input ---- */

static int l_input_open(lua_State *L)
{
    if (g_in_open) { lua_pushboolean(L, 1); return 1; }
    if (wr_input_open(&g_in) != 0) {
        lua_pushnil(L); lua_pushstring(L, "no input device opened"); return 2;
    }
    g_in_open = 1;
    lua_pushboolean(L, 1);
    return 1;
}

static int l_input_close(lua_State *L)
{
    (void)L;
    if (g_in_open) { wr_input_close(&g_in); g_in_open = 0; }
    return 0;
}

/* input_poll([timeout_ms=-1[, ignore_repeat=false]]) -> 键名字符串 | nil(超时/无合格键)
 * ignore_repeat=true 时跳过 auto-repeat，只认首次按下（菜单交互防长按重复触发）。
 * 按住 ScreenKB(面板 Keyboard 键) 时返回组合名 "ScreenKBPlus<Key>"（对齐 KOReader
 * hotkeys 事件名，如 ScreenKBPlusUp）；修饰键自身不产出事件。 */
static int l_input_poll(lua_State *L)
{
    int timeout = (int)luaL_optinteger(L, 1, -1);
    int ignore_repeat = lua_toboolean(L, 2);
    const char *name = NULL;
    if (!g_in_open) { lua_pushnil(L); return 1; }
    int rc = wr_input_poll(&g_in, timeout, &name, ignore_repeat);
    if (rc == 1 && name) lua_pushstring(L, name);
    else lua_pushnil(L);
    return 1;
}

/* ---- misc ---- */

static int l_millis(lua_State *L)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    lua_pushnumber(L, (lua_Number)ts.tv_sec * 1000.0 + (lua_Number)ts.tv_nsec / 1e6);
    return 1;
}

static const luaL_Reg wr_funcs[] = {
    { "fb_open",     l_fb_open     },
    { "fb_close",    l_fb_close    },
    { "fb_w",        l_fb_w        },
    { "fb_h",        l_fb_h        },
    { "fb_refresh",  l_fb_refresh  },
    { "fb_fill",     l_fb_fill     },
    { "fb_text",     l_fb_text     },
    { "fb_quant",    l_fb_quant    },
    { "fb_get",      l_fb_get      },
    { "font_load",   l_font_load   },
    { "font_close",  l_font_close  },
    { "fb_text_ft",  l_fb_text_ft  },
    { "font_width",  l_font_width  },
    { "input_open",  l_input_open  },
    { "input_close", l_input_close },
    { "input_poll",  l_input_poll  },
    { "millis",      l_millis      },
    { NULL, NULL }
};

int wr_register(lua_State *L)
{
    const luaL_Reg *f;
    lua_newtable(L);
    for (f = wr_funcs; f->name; f++) {
        lua_pushcfunction(L, f->func);
        lua_setfield(L, -2, f->name);
    }
    lua_setglobal(L, "wr");
    /* 网络层（net.c=动态变体真实现 / net_stub.c=静态占位）追加导出 */
    wr_net_register(L);
    return 0;
}

void wr_cleanup(void)
{
    wr_ft_done();  /* 字体在 fb 关闭前后均可释放，与设备无关 */
    if (g_in_open) { wr_input_close(&g_in); g_in_open = 0; }
    if (g_fb_open) {
        if (g_backup) {
            wr_fb_restore(&g_fb, g_backup, g_backup_cap);
            wr_fb_refresh_full(&g_fb, WR_FX_PARTIAL);
            wr_fb_wait(&g_fb);
        }
        wr_fb_close(&g_fb);
        g_fb_open = 0;
    }
    free(g_backup);
    g_backup = NULL;
    g_backup_cap = 0;
}

void wr_emergency_restore(void)
{
    /* 信号处理专用：仅 async-signal-safe 操作（见 signal-safety(7)）。
     * wr_ft_done/free/munmap 均会碰堆或不在安全清单，Ctrl+C 若打断 malloc
     * 会死锁或损坏堆——故此处只做屏幕恢复(memcpy)+ioctl+fsync 与输入释放
     * (ioctl+close)。fd 与内存映射由随后的 _exit() 回收，无需在此 close。 */
    if (g_in_open) { wr_input_close(&g_in); g_in_open = 0; }
    if (g_fb_open && g_backup) {
        wr_fb_restore(&g_fb, g_backup, g_backup_cap);
        wr_fb_refresh_full(&g_fb, WR_FX_PARTIAL);
        wr_fb_wait(&g_fb);
    }
}
