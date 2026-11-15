/* fb.h — K4 legacy einkfb 设备层封装。
 *
 * ABI 依据（K4Refresh v0.1.10，src/eink.rs，K4/K5 双机验证）：
 *   0x4600 FBIOGET_VSCREENINFO          面板分辨率/位深
 *   0x4602 FBIOGET_FSCREENINFO          物理布局（smem_len / line_length）
 *   0x46dd FBIO_EINK_UPDATE_DISPLAY_AREA 区域刷新（update_area_t*）
 *   0x46db FBIO_EINK_UPDATE_DISPLAY     整屏刷新（参数为 fx_type 值）
 *   fsync(fd) == 等待当前刷新完成
 *
 * fx 档位（legacy einkfb 无 waveform 概念，fx_type 是唯一刷新模式选择器）：
 *   0 partial 不闪 / 1 full 高保真低速（经 AREA 不闪）/ 2 fast 低保真 / 3 slow 闪烁清残影
 *
 * 结构体均为手工镜像（对齐 FBInk einkfb.h 与 KOReader einkfb_h.lua），
 * 不依赖工具链内核头版本；尾部留白保证缓冲不小于 2.6.31 内核的 struct。
 */
#ifndef WR_FB_H
#define WR_FB_H

#include <stdint.h>
#include <stddef.h>

#define WR_FBIO_EINK_UPDATE_DISPLAY       0x46dbUL
#define WR_FBIO_EINK_UPDATE_DISPLAY_AREA  0x46ddUL
#define WR_FBIOGET_VSCREENINFO            0x4600UL
#define WR_FBIOGET_FSCREENINFO            0x4602UL

#define WR_FX_PARTIAL 0
#define WR_FX_FULL    1
#define WR_FX_FAST    2
#define WR_FX_SLOW    3

/* struct update_area_t —— ARM32 上 24 字节；x2/y2 为右/下开边界（传 x+w/y+h）。 */
struct wr_update_area {
    int32_t x1, y1, x2, y2;
    int32_t which_fx;
    uint8_t *buffer;
};

struct wr_fb {
    int fd;
    uint32_t xres, yres, bpp;
    uint32_t line_length;
    uint32_t smem_len;
    uint8_t *mem;               /* mmap 后的 fb 首地址 */
};

/* 可见区总字节数（备份/恢复/量化的口径 = line_length * yres）。 */
static inline size_t wr_fb_visible_bytes(const struct wr_fb *fb)
{
    return (size_t)fb->line_length * fb->yres;
}

int  wr_fb_open(struct wr_fb *fb, const char *path);
void wr_fb_close(struct wr_fb *fb);

int  wr_fb_refresh_area(struct wr_fb *fb, const struct wr_update_area *a);
int  wr_fb_refresh_full(struct wr_fb *fb, int fx);
int  wr_fb_wait(struct wr_fb *fb);

/* Duokan 16 级 nibble 量化：v' = (v & 0xF0) | (v >> 4)，幂等，可整屏反复执行。 */
void wr_fb_quant(struct wr_fb *fb);

void wr_fb_fill_rect(struct wr_fb *fb, int32_t x, int32_t y,
                     int32_t w, int32_t h, uint8_t gray);

/* 原屏备份/恢复（调用方提供 wr_fb_visible_bytes(fb) 大小的缓冲）。 */
int  wr_fb_backup(struct wr_fb *fb, uint8_t *dst, size_t cap);
int  wr_fb_restore(struct wr_fb *fb, const uint8_t *src, size_t cap);

/* 量化恒等式的纯逻辑自测（8 组反汇编对齐向量 + 幂等性），0=通过。 */
int  wr_quant_selftest(void);

#endif
