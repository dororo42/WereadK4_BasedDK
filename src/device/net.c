/* net.c — libcurl HTTP(S) 实现（动态变体专用）。
 *
 * 复用多看 libcurl.so.4.3.0（curl 7.29.0 + OpenSSL 1.0.1e 内嵌）：
 * TLS 栈零编译，K4 十年服役先例（vendor/duokan/lib，NOTICE 标注）。
 * 仅导出最小面：http_get(url) -> body | nil, err。后续业务扩展在此层加。
 */
#include "net.h"

#include <curl/curl.h>

#include <lauxlib.h>
#include <stdlib.h>
#include <string.h>

#define WR_DEFAULT_CA "/mnt/us/weread/certs/ca-bundle.pem"
#define WR_TIMEOUT_S  30

struct wr_body {
    char  *buf;
    size_t len;
    size_t cap;
};

static size_t on_body(void *ptr, size_t size, size_t nmemb, void *ud)
{
    struct wr_body *b = ud;
    size_t add = size * nmemb;
    if (add == 0)
        return 0;
    if (b->len + add + 1 > b->cap) {
        size_t ncap = (b->len + add + 1) * 2;
        char *nbuf = realloc(b->buf, ncap);
        if (!nbuf)
            return 0;   /* 0 = 中断传输 */
        b->buf = nbuf;
        b->cap = ncap;
    }
    memcpy(b->buf + b->len, ptr, add);
    b->len += add;
    b->buf[b->len] = '\0';
    return add;
}

/* http_get(url) -> body(string) | nil, err
 *   CA 用设备 /mnt/us/weread/certs/ca-bundle.pem；跟随重定向；30s 超时。 */
static int l_http_get(lua_State *L)
{
    const char *url = luaL_checkstring(L, 1);
    CURL *c;
    struct wr_body b = { NULL, 0, 0 };
    char errbuf[CURL_ERROR_SIZE];
    int rc;
    long status = 0;

    c = curl_easy_init();
    if (!c) { lua_pushnil(L); lua_pushstring(L, "curl_easy_init failed"); return 2; }

    memset(errbuf, 0, sizeof(errbuf));
    curl_easy_setopt(c, CURLOPT_URL, url);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, on_body);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &b);
    curl_easy_setopt(c, CURLOPT_ERRORBUFFER, errbuf);
    curl_easy_setopt(c, CURLOPT_CAINFO, WR_DEFAULT_CA);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(c, CURLOPT_FOLLOWLOCATION, 1L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, (long)WR_TIMEOUT_S);
    curl_easy_setopt(c, CURLOPT_USERAGENT, "WereadK4/0.1");
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);   /* 老线程环境防 SIGSEGV 走信号 */

    rc = curl_easy_perform(c);
    if (rc == CURLE_OK)
        curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_cleanup(c);

    if (rc != CURLE_OK) {
        free(b.buf);
        lua_pushnil(L);
        lua_pushfstring(L, "curl rc=%d: %s", rc,
                        errbuf[0] ? errbuf : curl_easy_strerror(rc));
        return 2;
    }
    if (!b.buf) {
        b.buf = malloc(1);
        if (b.buf) b.buf[0] = '\0';
    }
    lua_pushlstring(L, b.buf ? b.buf : "", b.len);
    free(b.buf);
    lua_pushinteger(L, (lua_Integer)status);
    return 2;   /* body, status */
}

static const luaL_Reg net_funcs[] = {
    { "http_get", l_http_get },
    { NULL, NULL }
};

void wr_net_register(lua_State *L)
{
    const luaL_Reg *f;
    lua_getglobal(L, "wr");
    if (!lua_istable(L, -1)) {   /* 桥未注册时兜底建表 */
        lua_newtable(L);
        lua_setglobal(L, "wr");
        lua_getglobal(L, "wr");
    }
    for (f = net_funcs; f->name; f++) {
        lua_pushcfunction(L, f->func);
        lua_setfield(L, -2, f->name);
    }
    lua_pop(L, 1);   /* 弹出 wr 表 */
    curl_global_init(CURL_GLOBAL_DEFAULT);
}
