/* dyn_hello — DK-2 最小动态链接实验：TC(gcc14) 编码 + 设备 glibc 2.12.1 链接。
 * 验证点：设备 /lib/ld-linux.so.3 能否加载（符号版本不超过 2.12.1）。 */
#include <stdio.h>
#include <time.h>
int main(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    printf("dyn hello: %ld.%09ld\n", (long)ts.tv_sec, ts.tv_nsec);
    return 0;
}
