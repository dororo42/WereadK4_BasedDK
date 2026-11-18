/* net_stub.c — 网络层静态构建占位（无网络导出）。
 *
 * 静态变体（build/weread）不含 libcurl（闭包内 dlopen 不可行，见 inventory §四），
 * 网络能力由动态变体（build/weread-dyn）提供。桥接口不变。 */
#include "net.h"

void wr_net_register(lua_State *L)
{
    (void)L;
}
