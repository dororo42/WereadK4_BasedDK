/* input.c — K4 evdev 输入层实现。键码映射源自 KOReader event_map_kindle4.lua（设备实测）。
 *
 * ScreenKB(code 29) 是修饰键：wr_input_poll 内部 latch 其按下/抬起，并把它与其他键
 * 拼成 KOReader 同款组合事件名（ScreenKBPlusUp 等），修饰键自身不产出事件。
 * latch 挂在 struct wr_input 上（跨设备：code 29 在 event0，D-pad 在 event1）。 */
#include "input.h"

#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <time.h>
#include <errno.h>
#include <stddef.h>
#include <string.h>
#include <stdio.h>
#include <sys/ioctl.h>

#ifdef WR_INPUT_TEST_MAIN
#include <assert.h>
#endif

/* EVIOCGRAB：独占抓取 evdev 设备。前台全屏应用必须抓取，否则原生系统
 * （cvm/framework）会同时读键并重绘盖屏——与 KOReader 抢占同款机制。
 * 手工定义，不依赖工具链内核头版本（与 fb.h/input_event 同策略）。 */
#define WR_EVIOCGRAB _IOW('E', 0x90, int)

/* 内核 2.6.31 ARM32 struct input_event 手工镜像（16 字节）。
 * 不用 <linux/input.h>：与 fb.h 同款策略，不依赖工具链内核头版本，
 * 且显式 int32_t 时间字段避开 glibc time_t 尺寸歧义。 */
struct wr_input_event {
    int32_t  sec;
    int32_t  usec;
    uint16_t type;
    uint16_t code;
    int32_t  value;
};

#define WR_EV_SYN 0x00
#define WR_EV_KEY 0x01

static const char *const kDevs[WR_IN_MAXDEV] = {
    "/dev/input/event0",  /* tequila-keypad: Home/Back/Menu/翻页 */
    "/dev/input/event1",  /* fiveway: Up/Down/Left/Right/Press */
};

/* KOReader event_map_kindle4.lua（FW 3.x/4.x）子集 —— 菜单导航 + 翻页所需键。
 * 注意 Press 有两个码（28 中键 / 194 备用），都映射到 "Press"。 */
struct kmap { uint16_t code; const char *name; };
static const struct kmap kMap[] = {
    {  28, "Press"   },  /* fiveway 中键 / Enter */
    { 194, "Press"   },  /* 备用 Press 码 */
    { 103, "Up"      },
    { 108, "Down"    },
    { 105, "Left"    },
    { 106, "Right"   },
    { 102, "Home"    },
    { 139, "Menu"    },
    { 158, "Back"    },
    { 104, "LPgFwd"  },
    { 109, "RPgBack" },
    { 191, "RPgFwd"  },
    { 193, "LPgBack" },
    {  29, "ScreenKB"},  /* 修饰键：poll 内 latch，见 wr_key_combo */
};

const char *wr_key_name(uint16_t code)
{
    size_t i;
    for (i = 0; i < sizeof(kMap) / sizeof(kMap[0]); i++)
        if (kMap[i].code == code)
            return kMap[i].name;
    return NULL;
}

/* 修饰键 latch 的超时判据（纯函数，主机可测）：真机 code 29 可能不报 release
 * （键位手感验收预案，docs/keymap-k4.md §五）——距按下 >800ms 即视为已被释放，
 * 否则之后每一次普通按键都被拼成组合键。press_ms<0 = 未按下，恒不过期。 */
#define WR_MOD_TIMEOUT_MS 800L

int wr_mod_expired(long now_ms, long press_ms)
{
    if (press_ms < 0)
        return 0;
    return (now_ms - press_ms) > WR_MOD_TIMEOUT_MS;
}

const char *wr_key_combo(uint16_t code, int mod_held, char *buf, size_t buflen)
{
    const char *base = wr_key_name(code);
    if (!base)
        return NULL;
    if (!mod_held)
        return base;
    if (!buf || buflen == 0)
        return base;  /* 无缓冲可用时降级为基名，绝不写越界 */
    snprintf(buf, buflen, "ScreenKBPlus%s", base);
    return buf;
}

int wr_input_open(struct wr_input *in)
{
    int i;
    in->ndev = 0;
    in->mod_held = 0;
    in->mod_press_ms = -1;
    for (i = 0; i < WR_IN_MAXDEV; i++) {
        int one = 1;
        int fd = open(kDevs[i], O_RDONLY | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0)
            continue;  /* 单个设备缺失不致命，能开几个算几个 */
        /* 前台独占抓取。若已被他人（KOReader/原生）独占则 EBUSY 失败——
         * 此时本进程也收不到任何事件，需先让持有者退出。记录抓取状态供 close 释放。 */
        in->grabbed[in->ndev] = (ioctl(fd, WR_EVIOCGRAB, &one) == 0) ? 1 : 0;
        in->fds[in->ndev++] = fd;
    }
    return in->ndev > 0 ? 0 : -1;
}

void wr_input_close(struct wr_input *in)
{
    int i;
    for (i = 0; i < in->ndev; i++) {
        if (in->grabbed[i]) {
            int zero = 0;
            ioctl(in->fds[i], WR_EVIOCGRAB, &zero);  /* 释放独占，交还系统 */
        }
        close(in->fds[i]);
    }
    in->ndev = 0;
}

int wr_input_poll(struct wr_input *in, int timeout_ms, const char **name,
                  int ignore_repeat)
{
    long now_ms = -1;
    struct pollfd pfd[WR_IN_MAXDEV];
    int i, pr;

    if (in->ndev <= 0)
        return -1;

    /* latch 超时：即使 code 29 不报 release，超过时限也自动释放（防组合键粘住） */
    {
        struct timespec ts;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        now_ms = ts.tv_sec * 1000L + ts.tv_nsec / 1000000L;
        if (in->mod_held && wr_mod_expired(now_ms, in->mod_press_ms)) {
            in->mod_held = 0;
            in->mod_press_ms = -1;
        }
    }

    for (i = 0; i < in->ndev; i++) {
        pfd[i].fd = in->fds[i];
        pfd[i].events = POLLIN;
        pfd[i].revents = 0;
    }

    pr = poll(pfd, (nfds_t)in->ndev, timeout_ms);
    if (pr < 0)
        return errno == EINTR ? 0 : -1;
    if (pr == 0)
        return 0;  /* 超时，无按键 */

    for (i = 0; i < in->ndev; i++) {
        struct wr_input_event ev;
        ssize_t n;
        if (!(pfd[i].revents & POLLIN))
            continue;
        /* 排空该设备所有挂起事件，返回第一个合格的 press 键 */
        while ((n = read(in->fds[i], &ev, sizeof(ev))) == (ssize_t)sizeof(ev)) {
            if (ev.type != WR_EV_KEY)
                continue;
            /* 修饰键 latch：press/release 只更新状态，自身不产出事件（同 KOReader）。
             * 必须排在下面的 release 过滤之前，否则抬起被丢弃 → 修饰键粘住。 */
            if (ev.code == WR_KEY_MOD_CODE) {
                if (ev.value == WR_KEY_PRESS) {
                    in->mod_held = 1;
                    in->mod_press_ms = now_ms;
                } else if (ev.value == WR_KEY_RELEASE) {
                    in->mod_held = 0;
                    in->mod_press_ms = -1;
                }
                continue;
            }
            if (ev.value == WR_KEY_REPEAT && ignore_repeat)
                continue;  /* 忽略 auto-repeat，只认首次按下 */
            if (ev.value != WR_KEY_PRESS && ev.value != WR_KEY_REPEAT)
                continue;
            const char *nm = wr_key_combo(ev.code, in->mod_held,
                                          in->combo, sizeof(in->combo));
            if (nm) {
                if (name) *name = nm;  /* 指向 in->combo 时仅在下次 poll 前有效 */
                return 1;
            }
        }
    }
    return 0;
}

#ifdef WR_INPUT_TEST_MAIN
/* 主机侧：make host-selftest —— 只验组合键名拼装（纯函数，不碰 evdev/设备节点）。 */
int main(void)
{
    char buf[WR_IN_COMBO_LEN];
    int fail = 0;

#define EXPECT_STR(expr, want) do {                                     \
        const char *got_ = (expr);                                      \
        if (!got_ || strcmp(got_, (want)) != 0) {                       \
            printf("FAIL %s => %s (want %s)\n", #expr,                  \
                   got_ ? got_ : "(null)", (want));                     \
            fail = 1;                                                   \
        }                                                               \
    } while (0)

#define EXPECT_INT(expr, want) do {                                     \
        long got_ = (long)(expr);                                       \
        if (got_ != (long)(want)) {                                     \
            printf("FAIL %s => %ld (want %ld)\n", #expr, got_,          \
                   (long)(want));                                       \
            fail = 1;                                                   \
        }                                                               \
    } while (0)

    EXPECT_STR(wr_key_name(103), "Up");
    EXPECT_STR(wr_key_combo(103, 0, buf, sizeof buf), "Up");
    EXPECT_STR(wr_key_combo(103, 1, buf, sizeof buf), "ScreenKBPlusUp");
    EXPECT_STR(wr_key_combo(108, 1, buf, sizeof buf), "ScreenKBPlusDown");
    EXPECT_STR(wr_key_combo(28,  1, buf, sizeof buf), "ScreenKBPlusPress");
    /* 最长基名 ScreenKB(8) → 组合名 20 字符 + NUL，须装进 24 字节缓冲 */
    EXPECT_STR(wr_key_combo(29,  1, buf, sizeof buf), "ScreenKBPlusScreenKB");
    /* 无缓冲 / 零长度：降级为基名，不越界写 */
    EXPECT_STR(wr_key_combo(103, 1, NULL, 0), "Up");
    EXPECT_STR(wr_key_combo(103, 1, buf, 0), "Up");
    /* latch 超时判据（纯函数 wr_mod_expired）：未按下恒不过期；<800ms 不过期；>800ms 过期 */
    EXPECT_INT(wr_mod_expired(5000L, -1), 0);
    EXPECT_INT(wr_mod_expired(5700L, 5000L), 0);
    EXPECT_INT(wr_mod_expired(5801L, 5000L), 1);
    /* 未知 code：不产出名字 */
    if (wr_key_combo(9999, 1, buf, sizeof buf) != NULL) {
        printf("FAIL unknown code produced a name\n");
        fail = 1;
    }
    /* 缓冲过小：snprintf 截断但必须 NUL 结尾且写不出缓冲 */
    {
        char tiny[8];
        const char *r = wr_key_combo(103, 1, tiny, sizeof tiny);
        if (r != tiny || strlen(tiny) >= sizeof tiny) {
            printf("FAIL truncation not NUL-terminated in-bounds\n");
            fail = 1;
        }
    }

    if (!fail)
        printf("input combo selftest OK\n");
    return fail;
}
#endif
