/* evsniff.c — K4 输入设备诊断（一次性工具，不进主程序）。
 *
 * 用途：判定五向键/按键设备是否被其他进程（KOReader）EVIOCGRAB 独占抓取，
 * 并抓取原始事件核对键码。grab 测试即时给出结论，无需按键；事件抓取需按键。
 *
 * EVIOCGRAB 语义：成功抢到 = 之前无人独占（随即释放）；EBUSY = 已被他人独占。
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <sys/ioctl.h>

/* 手工镜像 2.6.31 ARM32 input_event（16 字节），避开 glibc time_t 歧义。 */
struct rev { int32_t sec, usec; uint16_t type, code; int32_t value; };

#define WR_EVIOCGNAME(len) _IOC(_IOC_READ, 'E', 0x06, len)
#define WR_EVIOCGRAB       _IOW('E', 0x90, int)

int main(int argc, char **argv)
{
    int secs = (argc > 1) ? atoi(argv[1]) : 2;
    struct pollfd pfd[8];
    int fds[8], nf = 0;

    for (int i = 0; i < 8; i++) {
        char path[64];
        snprintf(path, sizeof path, "/dev/input/event%d", i);
        int fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0)
            continue;
        char name[256];
        memset(name, 0, sizeof name);
        if (ioctl(fd, WR_EVIOCGNAME(sizeof name), name) < 0)
            snprintf(name, sizeof name, "(EVIOCGNAME errno %d)", errno);
        int one = 1, grabbed;
        if (ioctl(fd, WR_EVIOCGRAB, &one) == 0) {
            grabbed = 0;                 /* 抢到了 = 之前无人独占 */
            int zero = 0;
            ioctl(fd, WR_EVIOCGRAB, &zero);  /* 立即释放，绝不长占 */
        } else {
            grabbed = 1;                 /* EBUSY = 已被其他进程独占 */
        }
        printf("event%d fd=%d name='%s' %s\n", i, fd, name,
               grabbed ? "[GRABBED-by-other]" : "[free]");
        fflush(stdout);
        fds[nf] = fd;
        pfd[nf].fd = fd;
        pfd[nf].events = POLLIN;
        pfd[nf].revents = 0;
        nf++;
    }
    printf("polling %d device(s) for %d s — press keys now\n", nf, secs);
    fflush(stdout);

    int waited = 0;
    while (waited < secs * 1000) {
        int r = poll(pfd, nf, 500);
        waited += 500;
        if (r <= 0)
            continue;
        for (int j = 0; j < nf; j++) {
            if (!(pfd[j].revents & POLLIN))
                continue;
            struct rev buf[32];
            ssize_t n = read(fds[j], buf, sizeof buf);
            if (n <= 0)
                continue;
            for (ssize_t off = 0; off + (ssize_t)sizeof(struct rev) <= n;
                 off += sizeof(struct rev)) {
                struct rev *e = (struct rev *)((char *)buf + off);
                printf("  ev fd=%d type=%u code=%u value=%d\n",
                       fds[j], e->type, e->code, e->value);
                fflush(stdout);
            }
        }
    }
    for (int j = 0; j < nf; j++)
        close(fds[j]);
    return 0;
}
