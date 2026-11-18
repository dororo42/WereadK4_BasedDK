/* input.c — K4 evdev 输入层实现。键码映射源自 KOReader event_map_kindle4.lua（设备实测）。 */
#include "input.h"

#include <fcntl.h>
#include <unistd.h>
#include <poll.h>
#include <errno.h>
#include <stddef.h>
#include <sys/ioctl.h>

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
    {  29, "ScreenKB"},
};

const char *wr_key_name(uint16_t code)
{
    size_t i;
    for (i = 0; i < sizeof(kMap) / sizeof(kMap[0]); i++)
        if (kMap[i].code == code)
            return kMap[i].name;
    return NULL;
}

int wr_input_open(struct wr_input *in)
{
    int i;
    in->ndev = 0;
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
    struct pollfd pfd[WR_IN_MAXDEV];
    int i, pr;

    if (in->ndev <= 0)
        return -1;

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
            if (ev.value == WR_KEY_REPEAT && ignore_repeat)
                continue;  /* 忽略 auto-repeat，只认首次按下 */
            if (ev.value != WR_KEY_PRESS && ev.value != WR_KEY_REPEAT)
                continue;
            const char *nm = wr_key_name(ev.code);
            if (nm) {
                if (name) *name = nm;
                return 1;
            }
        }
    }
    return 0;
}
