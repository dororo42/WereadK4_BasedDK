/* fb.c — K4 legacy einkfb 设备层实现（ABI 与 K4Refresh src/eink.rs 逐字段对齐）。 */
#include "fb.h"

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#ifdef WR_QUANT_TEST_MAIN
#include <stdio.h>
#endif

/* fb_var_screeninfo 的"够用"镜像：只读前 7 个字段，尾部 256 字节占位，
 * 保证缓冲不小于 2.6.31~4.x 内核的 struct（内核只写它自己的 sizeof）。 */
struct wr_var_screeninfo {
    uint32_t xres, yres;
    uint32_t xres_virtual, yres_virtual;
    uint32_t xoffset, yoffset;
    uint32_t bits_per_pixel;
    uint8_t _tail[256];
};

/* fb_fix_screeninfo 的"够用"镜像（ARM32：smem_start 为 4 字节 ulong；
 * xpanstep/ypanstep/ywrapstep 后由编译器自动补 2 字节对齐 line_length）。 */
struct wr_fix_screeninfo {
    char id[16];
    uint32_t smem_start;
    uint32_t smem_len;
    uint32_t type;
    uint32_t type_aux;
    uint32_t visual;
    uint16_t xpanstep, ypanstep, ywrapstep;
    uint16_t pad;
    uint32_t line_length;
    uint8_t _tail[256];
};

static int wr_ioctl_ptr(int fd, unsigned long req, void *arg)
{
    return ioctl(fd, req, arg);
}

int wr_fb_open(struct wr_fb *fb, const char *path)
{
    struct wr_var_screeninfo var;
    struct wr_fix_screeninfo fix;

    memset(fb, 0, sizeof(*fb));
    fb->fd = open(path, O_RDWR);
    if (fb->fd < 0)
        return -errno;

    memset(&var, 0, sizeof(var));
    if (wr_ioctl_ptr(fb->fd, WR_FBIOGET_VSCREENINFO, &var) < 0) {
        int e = errno;
        close(fb->fd);
        fb->fd = -1;
        return -e;
    }
    memset(&fix, 0, sizeof(fix));
    if (wr_ioctl_ptr(fb->fd, WR_FBIOGET_FSCREENINFO, &fix) < 0) {
        int e = errno;
        close(fb->fd);
        fb->fd = -1;
        return -e;
    }

    fb->xres = var.xres;
    fb->yres = var.yres;
    fb->bpp = var.bits_per_pixel;
    fb->line_length = fix.line_length;
    fb->smem_len = fix.smem_len;

    if (fb->bpp != 8) {
        int e = EINVAL;  /* DK-0 只支持 8bpp；显式拒绝而非错误绘制。 */
        close(fb->fd);
        fb->fd = -1;
        return -e;
    }
    if (fb->smem_len == 0 || fb->line_length == 0) {
        int e = EINVAL;
        close(fb->fd);
        fb->fd = -1;
        return -e;
    }

    fb->mem = mmap(NULL, fb->smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fb->fd, 0);
    if (fb->mem == MAP_FAILED) {
        int e = errno;
        fb->mem = NULL;
        close(fb->fd);
        fb->fd = -1;
        return -e;
    }
    return 0;
}

void wr_fb_close(struct wr_fb *fb)
{
    if (fb->mem)
        munmap(fb->mem, fb->smem_len);
    if (fb->fd >= 0)
        close(fb->fd);
    fb->mem = NULL;
    fb->fd = -1;
}

int wr_fb_refresh_area(struct wr_fb *fb, const struct wr_update_area *a)
{
    struct wr_update_area tmp = *a;
    if (wr_ioctl_ptr(fb->fd, WR_FBIO_EINK_UPDATE_DISPLAY_AREA, &tmp) < 0)
        return -errno;
    return 0;
}

int wr_fb_refresh_full(struct wr_fb *fb, int fx)
{
    /* 整屏分支参数为 fx 值本身（FBInk refresh_legacy 同款）。 */
    if (wr_ioctl_ptr(fb->fd, WR_FBIO_EINK_UPDATE_DISPLAY,
                     (void *)(unsigned long)fx) < 0)
        return -errno;
    return 0;
}

int wr_fb_wait(struct wr_fb *fb)
{
    if (fsync(fb->fd) < 0)
        return -errno;
    return 0;
}

void wr_fb_quant(struct wr_fb *fb)
{
    uint32_t y;
    for (y = 0; y < fb->yres; y++) {
        uint8_t *row = fb->mem + (size_t)y * fb->line_length;
        uint32_t x;
        for (x = 0; x < fb->xres; x++) {
            uint8_t v = row[x];
            row[x] = (uint8_t)((v & 0xF0) | (v >> 4));
        }
    }
}

void wr_fb_fill_rect(struct wr_fb *fb, int32_t x, int32_t y,
                     int32_t w, int32_t h, uint8_t gray)
{
    int32_t x2 = (x + w < (int32_t)fb->xres) ? (x + w) : (int32_t)fb->xres;
    int32_t y2 = (y + h < (int32_t)fb->yres) ? (y + h) : (int32_t)fb->yres;
    int32_t iy;

    if (x < 0)
        x = 0;
    if (y < 0)
        y = 0;
    if (x >= x2 || y >= y2)
        return;
    for (iy = y; iy < y2; iy++) {
        uint8_t *row = fb->mem + (size_t)iy * fb->line_length;
        memset(row + x, gray, (size_t)(x2 - x));
    }
}

int wr_fb_backup(struct wr_fb *fb, uint8_t *dst, size_t cap)
{
    size_t need = wr_fb_visible_bytes(fb);
    if (cap < need)
        return -ENOMEM;
    memcpy(dst, fb->mem, need);
    return 0;
}

int wr_fb_restore(struct wr_fb *fb, const uint8_t *src, size_t cap)
{
    size_t need = wr_fb_visible_bytes(fb);
    if (cap < need)
        return -ENOMEM;
    memcpy(fb->mem, src, need);
    return 0;
}

int wr_quant_selftest(void)
{
    static const uint8_t in[8]  = { 0x00, 0xFF, 0x08, 0x18, 0xF8, 0x7F, 0x80, 0x10 };
    static const uint8_t out[8] = { 0x00, 0xFF, 0x00, 0x11, 0xFF, 0x77, 0x88, 0x11 };
    uint8_t b[8];
    int i;

    memcpy(b, in, sizeof(b));
    for (i = 0; i < 8; i++)
        b[i] = (uint8_t)((b[i] & 0xF0) | (b[i] >> 4));
    if (memcmp(b, out, sizeof(b)) != 0)
        return -1;

    /* 幂等性：再量化一遍必须不动。 */
    for (i = 0; i < 8; i++)
        b[i] = (uint8_t)((b[i] & 0xF0) | (b[i] >> 4));
    if (memcmp(b, out, sizeof(b)) != 0)
        return -2;
    return 0;
}

#ifdef WR_QUANT_TEST_MAIN
/* 主机侧：make host-selftest —— 只跑量化自测，不碰 fb。 */
int main(void)
{
    int rc = wr_quant_selftest();
    if (rc != 0)
        printf("quant selftest FAIL rc=%d\n", rc);
    return rc == 0 ? 0 : 1;
}
#endif
