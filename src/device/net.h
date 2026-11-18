/* net.h — HTTP(S) 网络层（libcurl）。
 *
 * 仅动态变体（weread-dyn）编译本实现：复用多看 libcurl.so.4.3.0
 * （curl 7.29.0 + OpenSSL 1.0.1e 内嵌，vendor/duokan/lib，NOTICE 标注）。
 * 静态变体链接 net_stub.c（同接口 no-op），桥代码无差别。
 */
#ifndef WR_NET_H
#define WR_NET_H

#include <lua.h>

/* 向全局 "wr" 表追加网络导出（http_get 等）。静态构建为 no-op。 */
void wr_net_register(lua_State *L);

#endif
