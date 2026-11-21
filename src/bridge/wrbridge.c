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

/* stb_image（public domain，upstream master 2019-2025 副本，零改动）：jpeg/png/bmp/gif
 * 全解码，无外部依赖——设备 /usr/lib 有 libjpeg 但 ffi.load 失败，且手工绑
 * libjpeg 的 struct/jmp 语义风险高，统一走 stb 单实现。 */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ASSERT(x) do { } while (0)
#include "stb_image.h"

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

/* fb_image(x, y, w, h, gray): 8-bit 灰度块直写 fb。
 * 灰度语义 = 亮度（0=黑 255=白）；fb 是墨量（0x00=白 0xFF=黑）→ 写 255-gray。
 * 越界部分裁剪，不越界整块才画（调用方负责缩放到屏宽内）。 */
static int l_fb_image(lua_State *L)
{
    if (!g_fb_open) { lua_pushnil(L); lua_pushstring(L, "fb not open"); return 2; }
    int x = (int)luaL_checkinteger(L, 1);
    int y = (int)luaL_checkinteger(L, 2);
    int w = (int)luaL_checkinteger(L, 3);
    int h = (int)luaL_checkinteger(L, 4);
    size_t glen;
    const char *gray = luaL_checklstring(L, 5, &glen);
    if (w <= 0 || h <= 0 || (size_t)(w * h) > glen) {
        lua_pushnil(L); lua_pushstring(L, "fb_image size mismatch"); return 2;
    }
    for (int ry = 0; ry < h; ry++) {
        int py = y + ry;
        if (py < 0 || py >= (int)g_fb.yres) continue;
        for (int rx = 0; rx < w; rx++) {
            int px = x + rx;
            if (px < 0 || px >= (int)g_fb.xres) continue;
            g_fb.mem[(size_t)py * g_fb.line_length + px] = (uint8_t)(255 - (uint8_t)gray[ry * w + rx]);
        }
    }
    lua_pushboolean(L, 1);
    return 1;
}

/* image_decode(bytes) -> w, h, gray_string | nil, err。
 * 期望单通道灰度输出（stbi desired_channels=1）；解码失败（非图/裁断）返回 nil。 */
static int l_image_decode(lua_State *L)
{
    size_t dlen;
    const char *data = luaL_checklstring(L, 1, &dlen);
    int w, h, n;
    stbi_uc *px = stbi_load_from_memory((const stbi_uc *)data, (int)dlen, &w, &h, &n, 1);
    if (!px) {
        lua_pushnil(L); lua_pushstring(L, stbi_failure_reason());
        return 2;
    }
    size_t sz = (size_t)w * h;
    lua_pushlstring(L, (const char *)px, sz);
    stbi_image_free(px);
    lua_pushinteger(L, w);
    lua_pushinteger(L, h);
    return 3;
}

/* image_scale(gray, w, h, dw, dh) -> 缩放后的灰度串（最近邻点采样）。
 * 在 C 层做缩放：Lua 侧拼 60 万参数的 string.char 会爆栈。 */
static int l_image_scale(lua_State *L)
{
    size_t glen;
    const char *gray = luaL_checklstring(L, 1, &glen);
    int w = (int)luaL_checkinteger(L, 2);
    int h = (int)luaL_checkinteger(L, 3);
    int dw = (int)luaL_checkinteger(L, 4);
    int dh = (int)luaL_checkinteger(L, 5);
    if (w <= 0 || h <= 0 || dw <= 0 || dh <= 0 || (size_t)(w * h) > glen
        || (size_t)(dw * dh) > (size_t)1 << 22) {
        lua_pushnil(L); lua_pushstring(L, "bad scale params"); return 2;
    }
    size_t sz = (size_t)dw * dh;
    char *out = (char *)malloc(sz);
    if (!out) { lua_pushnil(L); lua_pushstring(L, "oom"); return 2; }
    for (int dy = 0; dy < dh; dy++) {
        int sy = (int)((double)dy * h / dh + 0.5);
        if (sy >= h) sy = h - 1;
        const char *src = gray + (size_t)sy * w;
        char *dst = out + (size_t)dy * dw;
        for (int dx = 0; dx < dw; dx++) {
            int sx = (int)((double)dx * w / dw + 0.5);
            if (sx >= w) sx = w - 1;
            dst[dx] = src[sx];
        }
    }
    lua_pushlstring(L, out, sz);
    free(out);
    return 1;
}

/* ---- zip（epub 导出）----
 * 最小 store 型 zip 写入器：CRC32 + local header（顺序落盘）+ central
 * directory（内存攒齐）+ EOCD。epub 规范要求 mimetype 首条——全 store
 * 不压缩天然满足。entry≤4096、总载荷≤64MB（防 OOM）。
 * mimetype 提前由两遍扫描实现（pass0 只处理 mimetype）。 */

static uint32_t wr_crc32(const uint8_t *data, size_t len)
{
    static uint32_t table[256];
    static int table_ready;
    if (!table_ready) {
        for (uint32_t i = 0; i < 256; i++) {
            uint32_t c = i;
            for (int k = 0; k < 8; k++)
                c = (c & 1) ? 0xEDB88320u ^ (c >> 1) : c >> 1;
            table[i] = c;
        }
        table_ready = 1;
    }
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; i++)
        crc = table[(crc ^ data[i]) & 0xFF] ^ (crc >> 8);
    return crc ^ 0xFFFFFFFFu;
}

static void wr_zip_le32(uint8_t *p, uint32_t v)
{
    p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF; p[2] = (v >> 16) & 0xFF; p[3] = (v >> 24) & 0xFF;
}

static void wr_zip_le16(uint8_t *p, uint16_t v)
{
    p[0] = v & 0xFF; p[1] = (v >> 8) & 0xFF;
}

struct wr_zip_cd {
    uint32_t crc, csize, offset;
};

/* zip_write(path, tbl)：tbl = { [name]=data, ... }。true | nil, err。
 * 实现口径：先把 (name,data) 全量快照拷进 malloc 数组再写——lua_next 迭代
 * 中途用 lua_tostring 会原地改键类型（数字键变字符串键），续代直接
 * "invalid key to 'next'"（真机实证）。快照后无 lua_next，顺序确定。 */
static int l_zip_write(lua_State *L)
{
    const char *path = luaL_checkstring(L, 1);
    luaL_checktype(L, 2, LUA_TTABLE);

    int n = 0, cap = 64;
    struct wr_zip_cd *cds = (struct wr_zip_cd *)malloc(cap * sizeof(*cds));
    char **names = (char **)malloc(cap * sizeof(*names));
    char **datas = (char **)malloc(cap * sizeof(*datas));
    uint32_t *dlen_v = (uint32_t *)malloc(cap * sizeof(*dlen_v));
    size_t payload = 0, cd_len = 0, cd_cap = 0;
    uint8_t *cd_buf = NULL;
    const char *fail = NULL;

    if (!cds || !names || !datas || !dlen_v) fail = "oom";

    /* 快照（单次 lua_next；字符串立即拷贝，栈不再参与后续流程） */
    for (lua_pushnil(L); lua_next(L, 2) && !fail; lua_pop(L, 1)) {
        const char *name = lua_tostring(L, -2);
        const char *data = lua_tostring(L, -1);
        size_t nlen = name ? strlen(name) : 0;
        size_t dlen = 0;
        if (data) dlen = lua_objlen(L, -1);
        if (!name || !data) {
            fail = "zip entries must be string=string";
        } else if (n == cap) {
            cap *= 2;
            cds = (struct wr_zip_cd *)realloc(cds, cap * sizeof(*cds));
            names = (char **)realloc(names, cap * sizeof(*names));
            datas = (char **)realloc(datas, cap * sizeof(*datas));
            dlen_v = (uint32_t *)realloc(dlen_v, cap * sizeof(*dlen_v));
            if (!cds || !names || !datas || !dlen_v) fail = "oom";
        }
        if (!fail && (nlen >= 256 || n > 4096 || payload + dlen > ((size_t)64 << 20))) {
            fail = "zip limits exceeded";
        }
        if (!fail) {
            names[n] = (char *)malloc(nlen + 1);
            datas[n] = (char *)malloc(dlen + 1);
            if (!names[n] || !datas[n]) { fail = "oom"; }
            else {
                memcpy(names[n], name, nlen + 1);
                memcpy(datas[n], data, dlen);
                dlen_v[n] = (uint32_t)dlen;
                n++;
                payload += dlen;
            }
        }
    }
    lua_pop(L, 1);   /* 收尾 lua_next 留下的 key（fail-break 时已多 pop 一层则再补） */

    /* mimetype 提到首位（epub 规范：首条且未压缩） */
    for (int i = 1; i < n && !fail; i++) {
        if (strcmp(names[i], "mimetype") == 0) {
            char *tn = names[0]; char *td = datas[0]; uint32_t tl = dlen_v[0];
            names[0] = names[i]; datas[0] = datas[i]; dlen_v[0] = dlen_v[i];
            names[i] = tn; datas[i] = td; dlen_v[i] = tl;
            break;
        }
    }

    FILE *f = fopen(path, "wb");
    if (!f) fail = "open zip failed";
    if (!fail && n == 0) fail = "empty zip";

    if (!fail) {
        for (int i = 0; i < n; i++) {
            size_t nlen = strlen(names[i]);
            uint32_t crc = wr_crc32((const uint8_t *)datas[i], dlen_v[i]);
            long offset = ftell(f);
            uint8_t lfh[30] = {0};
            wr_zip_le32(lfh + 0, 0x04034b50u);
            wr_zip_le16(lfh + 4, 20);
            wr_zip_le16(lfh + 6, 0);
            wr_zip_le16(lfh + 8, 0);                     /* method = store */
            wr_zip_le32(lfh + 14, crc);
            wr_zip_le32(lfh + 18, dlen_v[i]);
            wr_zip_le32(lfh + 22, dlen_v[i]);
            wr_zip_le16(lfh + 26, (uint16_t)nlen);
            fwrite(lfh, 1, 30, f);
            fwrite(names[i], 1, nlen, f);
            fwrite(datas[i], 1, dlen_v[i], f);

            size_t need = cd_len + 46 + nlen;
            if (need > cd_cap) {
                cd_cap = need * 2 + 256;
                cd_buf = (uint8_t *)realloc(cd_buf, cd_cap);
                if (!cd_buf) { fail = "oom"; break; }
            }
            uint8_t *c = cd_buf + cd_len;
            memset(c, 0, 46);
            wr_zip_le32(c + 0, 0x02014b50u);
            wr_zip_le16(c + 4, 20); wr_zip_le16(c + 6, 20);
            wr_zip_le32(c + 16, crc);
            wr_zip_le32(c + 20, dlen_v[i]);
            wr_zip_le32(c + 24, dlen_v[i]);
            wr_zip_le16(c + 28, (uint16_t)nlen);
            wr_zip_le32(c + 42, (uint32_t)offset);   /* local header offset @42 */
            wr_zip_le32(c + 36, 0);                  /* external attrs @36..41 */

            memcpy(c + 46, names[i], nlen);
            cd_len += 46 + nlen;
            (void)crc;
        }
    }
    if (!fail) {
        long cd_offset = ftell(f);
        fwrite(cd_buf, 1, cd_len, f);
        uint8_t eocd[22] = {0};
        wr_zip_le32(eocd + 0, 0x06054b50u);
        wr_zip_le16(eocd + 8, (uint16_t)n);
        wr_zip_le16(eocd + 10, (uint16_t)n);
        wr_zip_le32(eocd + 12, (uint32_t)cd_len);
        wr_zip_le32(eocd + 16, (uint32_t)cd_offset);
        fwrite(eocd, 1, 22, f);
        if (ferror(f)) fail = "write failed";
    }
    if (f) fclose(f);
    for (int i = 0; i < n; i++) { free(names[i]); free(datas[i]); }
    free(names); free(datas); free(dlen_v); free(cds); free(cd_buf);
    if (fail) {
        remove(path);
        lua_pushnil(L); lua_pushstring(L, fail);
        return 2;
    }
    lua_pushboolean(L, 1);
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
    { "fb_image",    l_fb_image    },
    { "image_decode", l_image_decode },
    { "image_scale",  l_image_scale  },
    { "zip_write",    l_zip_write    },
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
