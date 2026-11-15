/* main.c — DK-0 fbtest：fb mmap + 画测试图 + 0x46dd 刷新的最小验证程序。
 *
 * DK-1 起该入口将被 LuaJIT VM 主进程替换；fb.c 设备层保持不变。
 *
 * 验证标准（技术方案 §五 DK-0）：屏幕可见变化 + 退出码 0 + 无内核报错。
 * 流程：quant 自测 → 原屏备份 → 画图 → 量化 → 区域刷新 → 停留 → 恢复原屏 → 刷新。
 * 安全回滚：任何退出路径（含刷新失败、SIGINT/SIGTERM）都先恢复原屏再退出。
 */
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "fb.h"

static volatile sig_atomic_t g_abort = 0;

static void on_signal(int sig)
{
    (void)sig;
    g_abort = 1;
}

static void draw_test_pattern(struct wr_fb *fb)
{
    uint32_t i;

    /* 白底 */
    wr_fb_fill_rect(fb, 0, 0, (int32_t)fb->xres, (int32_t)fb->yres, 0xFF);

    /* 边框：验证整屏边界与 line_length 口径 */
    wr_fb_fill_rect(fb, 0, 0, (int32_t)fb->xres, 4, 0x00);
    wr_fb_fill_rect(fb, 0, (int32_t)fb->yres - 4, (int32_t)fb->xres, 4, 0x00);
    wr_fb_fill_rect(fb, 0, 0, 4, (int32_t)fb->yres, 0x00);
    wr_fb_fill_rect(fb, (int32_t)fb->xres - 4, 0, 4, (int32_t)fb->yres, 0x00);

    /* 16 级渐变条（顶部 100 行）：量化后逐条呈现 17n 灰阶，验证 nibble 双写。
     * xres/16 整除余数落在最右白底内，仅装饰性缺口，不影响验证。 */
    for (i = 0; i < 16; i++)
        wr_fb_fill_rect(fb, (int32_t)i * (int32_t)(fb->xres / 16), 24,
                        (int32_t)(fb->xres / 16), 100, (uint8_t)(i << 4));

    /* 中央黑块：方案 DK-0 的"画一个方块"验收项 */
    wr_fb_fill_rect(fb, (int32_t)fb->xres / 2 - 60, (int32_t)fb->yres / 2 - 60,
                    120, 120, 0x00);
}

/* 恢复原屏：写回 + 量化（幂等）+ 同口径全屏刷新 + 等待完成。返回 0 = 成功。 */
static int restore_screen(struct wr_fb *fb, uint8_t *backup, size_t cap)
{
    struct wr_update_area a = {
        .x1 = 0, .y1 = 0,
        .x2 = (int32_t)fb->xres, .y2 = (int32_t)fb->yres,
        .which_fx = WR_FX_FULL,
        .buffer = NULL,
    };
    int rc = wr_fb_restore(fb, backup, cap);
    if (rc != 0)
        return rc;
    wr_fb_quant(fb);
    rc = wr_fb_refresh_area(fb, &a);
    if (rc == 0)
        rc = wr_fb_wait(fb);
    return rc;
}

/* 分片睡眠，信号置位即提前返回；避免 sleep 被信号打断后跳过恢复。 */
static void sleep_abortable(int seconds)
{
    struct timespec ts = { .tv_sec = 0, .tv_nsec = 100 * 1000 * 1000 };
    int remain = seconds * 10;
    while (remain-- > 0 && !g_abort)
        nanosleep(&ts, NULL);
}

int main(int argc, char **argv)
{
    struct wr_fb fb;
    struct sigaction sa;
    uint8_t *backup = NULL;
    size_t backup_cap;
    int delay = 5;
    int rc, restore_rc, exit_code = 0;

    if (argc > 1)
        delay = atoi(argv[1]);
    if (delay < 1)
        delay = 1;

    rc = wr_quant_selftest();
    if (rc != 0) {
        printf("quant selftest FAIL rc=%d\n", rc);
        return 1;
    }
    printf("quant selftest PASS\n");

    rc = wr_fb_open(&fb, "/dev/fb0");
    if (rc != 0) {
        printf("fb open FAIL rc=%d\n", rc);
        return 1;
    }
    printf("fb: %ux%u@%ubpp line_length=%u smem_len=%u\n",
           fb.xres, fb.yres, fb.bpp, fb.line_length, fb.smem_len);

    backup_cap = wr_fb_visible_bytes(&fb);
    backup = malloc(backup_cap);
    if (!backup || wr_fb_backup(&fb, backup, backup_cap) != 0) {
        printf("backup FAIL\n");
        free(backup);
        wr_fb_close(&fb);
        return 1;
    }

    /* SIGINT/SIGTERM 只置位，不直接退出——恢复动作在主流程统一执行。 */
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, NULL);
    sigaction(SIGTERM, &sa, NULL);

    draw_test_pattern(&fb);
    wr_fb_quant(&fb);

    {
        struct wr_update_area a = {
            .x1 = 0, .y1 = 0,
            .x2 = (int32_t)fb.xres, .y2 = (int32_t)fb.yres,
            .which_fx = WR_FX_FULL,
            .buffer = NULL,
        };
        rc = wr_fb_refresh_area(&fb, &a);
        if (rc == 0)
            rc = wr_fb_wait(&fb);
    }
    if (rc != 0) {
        printf("refresh area FAIL rc=%d, restoring\n", rc);
        exit_code = 1;
        goto out;
    }

    printf("pattern on screen, sleeping %ds\n", delay);
    sleep_abortable(delay);
    if (g_abort)
        printf("interrupted, restoring\n");

out:
    restore_rc = restore_screen(&fb, backup, backup_cap);
    if (restore_rc != 0) {
        printf("restore FAIL rc=%d\n", restore_rc);
        exit_code = 1;
    }

    free(backup);
    wr_fb_close(&fb);
    if (exit_code == 0)
        printf("fbtest OK\n");
    /* 真实失败码优先；否则中断用 130（shell 惯例 128+SIGINT）标识。 */
    return exit_code != 0 ? exit_code : (g_abort ? 130 : 0);
}
