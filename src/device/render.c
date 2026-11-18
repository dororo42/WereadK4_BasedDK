/* render.c — freetype 文字渲染实现（8bpp fb 直绘）。
 *
 * 坐标约定：draw(x, y) 的 y 是行顶；基线 = y + ascender/64（26.6 定点）。
 * 字形混合：dst = (dst*(255-cov) + fg*cov + 127) / 255（背景透明，cov 为抗锯齿覆盖度）。
 * 越界像素裁剪；行 stride 用 fb->line_length，只动可见列。
 */
#include "render.h"

#include <ft2build.h>
#include FT_FREETYPE_H

#include <errno.h>
#include <string.h>

static FT_Library g_lib;
static int g_lib_ready;
static struct { FT_Face face; int used; } g_fonts[WR_FT_MAX_FONTS];

int wr_ft_init(void)
{
    if (g_lib_ready)
        return 0;
    if (FT_Init_FreeType(&g_lib) != 0)
        return -ENOMEM;
    g_lib_ready = 1;
    return 0;
}

void wr_ft_done(void)
{
    int i;
    for (i = 0; i < WR_FT_MAX_FONTS; i++) {
        if (g_fonts[i].used) {
            FT_Done_Face(g_fonts[i].face);
            g_fonts[i].face = NULL;
            g_fonts[i].used = 0;
        }
    }
    if (g_lib_ready) {
        FT_Done_FreeType(g_lib);
        g_lib = NULL;
        g_lib_ready = 0;
    }
}

int wr_ft_load(const char *path, int px_size)
{
    int i, rc;

    if (px_size < 6 || px_size > 96)
        return -EINVAL;
    rc = wr_ft_init();
    if (rc != 0)
        return rc;
    for (i = 0; i < WR_FT_MAX_FONTS; i++)
        if (!g_fonts[i].used)
            break;
    if (i == WR_FT_MAX_FONTS)
        return -ENOMEM;
    if (FT_New_Face(g_lib, path, 0, &g_fonts[i].face) != 0)
        return -ENOENT;
    if (FT_Set_Pixel_Sizes(g_fonts[i].face, 0, (FT_UInt)px_size) != 0) {
        FT_Done_Face(g_fonts[i].face);
        g_fonts[i].face = NULL;
        return -EINVAL;
    }
    g_fonts[i].used = 1;
    return i;
}

void wr_ft_unload(int id)
{
    if (id < 0 || id >= WR_FT_MAX_FONTS || !g_fonts[id].used)
        return;
    FT_Done_Face(g_fonts[id].face);
    g_fonts[id].face = NULL;
    g_fonts[id].used = 0;
}

/* UTF-8 解码：返回 codepoint（非法/截断返回 0 并前进 1 字节）。 */
static unsigned decode_utf8(const char **p)
{
    const unsigned char *s = (const unsigned char *)*p;
    unsigned char c = s[0];
    unsigned cp;
    int n, i;

    if (c < 0x80)                { cp = c; n = 1; }
    else if ((c & 0xE0) == 0xC0) { cp = c & 0x1Fu; n = 2; }
    else if ((c & 0xF0) == 0xE0) { cp = c & 0x0Fu; n = 3; }
    else if ((c & 0xF8) == 0xF0) { cp = c & 0x07u; n = 4; }
    else { (*p)++; return 0; }
    for (i = 1; i < n; i++) {
        unsigned char cc = s[i];
        if ((cc & 0xC0) != 0x80) { *p = (const char *)(s + 1); return 0; }
        cp = (cp << 6) | (cc & 0x3Fu);
    }
    *p = (const char *)(s + n);
    return cp;
}

static int font_check(int id)
{
    if (id < 0 || id >= WR_FT_MAX_FONTS || !g_fonts[id].used)
        return -EBADF;
    return 0;
}

/* 公共循环：draw=1 渲染混合，draw=0 只累积 advance。返回结束 x。 */
static int ft_run(struct wr_fb *fb, FT_Face face, int x, int y,
                  const char *utf8, uint8_t fg, int draw)
{
    const char *p = utf8;
    int cx = x;
    int base_y = y + (int)(face->size->metrics.ascender >> 6);

    while (*p) {
        unsigned cp = decode_utf8(&p);
        if (FT_Load_Char(face, cp, draw ? FT_LOAD_RENDER : FT_LOAD_DEFAULT) != 0)
            continue;
        cx += (int)(face->glyph->advance.x >> 6);
        if (!draw)
            continue;
        if (face->glyph->format != FT_GLYPH_FORMAT_BITMAP)
            continue;
        {
            FT_Bitmap *bm = &face->glyph->bitmap;
            int gx = cx - (int)(face->glyph->advance.x >> 6) + face->glyph->bitmap_left;
            int gy = base_y - face->glyph->bitmap_top;
            unsigned r, c;

            for (r = 0; r < bm->rows; r++) {
                int dy = gy + (int)r;
                const uint8_t *srow;
                if (dy < 0 || dy >= (int)fb->yres)
                    continue;
                srow = bm->buffer + r * (unsigned)bm->pitch;
                for (c = 0; c < bm->width; c++) {
                    int dx = gx + (int)c;
                    uint8_t *dst;
                    uint32_t cov;
                    if (dx < 0 || dx >= (int)fb->xres)
                        continue;
                    cov = srow[c];
                    if (cov == 0)
                        continue;
                    dst = fb->mem + (size_t)dy * fb->line_length + dx;
                    *dst = (uint8_t)((dst[0] * (255u - cov) + (uint32_t)fg * cov + 127u) / 255u);
                }
            }
        }
    }
    return cx;
}

int wr_ft_draw(struct wr_fb *fb, int id, int x, int y, const char *utf8, uint8_t fg)
{
    int rc = font_check(id);
    if (rc != 0)
        return rc;
    return ft_run(fb, g_fonts[id].face, x, y, utf8, fg, 1);
}

int wr_ft_width(int id, const char *utf8)
{
    int rc = font_check(id);
    if (rc != 0)
        return rc;
    return ft_run(NULL, g_fonts[id].face, 0, 0, utf8, 0, 0);
}
