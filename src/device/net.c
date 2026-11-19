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

/* 响应头收集：逐行回调，同名头用 "\n" 连接（Set-Cookie 多值语义，Lua 侧 split）。 */
struct wr_hdrs {
    char  *buf;
    size_t len;
    size_t cap;
};

static void hdrs_append(struct wr_hdrs *h, const char *line, size_t n)
{
    if (h->len + n + 1 > h->cap) {
        size_t ncap = (h->len + n + 1) * 2;
        char *nbuf = realloc(h->buf, ncap);
        if (!nbuf)
            return;
        h->buf = nbuf;
        h->cap = ncap;
    }
    memcpy(h->buf + h->len, line, n);
    h->len += n;
    h->buf[h->len] = '\0';
}

static size_t on_header(char *ptr, size_t size, size_t nmemb, void *ud)
{
    struct wr_hdrs *h = ud;
    size_t total = size * nmemb;
    char *line = ptr;

    /* 去掉行尾 \r\n；跳过 HTTP/ 状态行与空行 */
    while (total > 0 && (line[total - 1] == '\n' || line[total - 1] == '\r'))
        total--;
    if (total == 0 || total > 6 || memcmp(line, "HTTP/", 6) == 0)
        return size * nmemb;
    {
        char *colon = memchr(line, ':', total);
        if (colon && colon != line) {
            char name[64];
            size_t nlen = (size_t)(colon - line);
            const char *val = colon + 1;
            size_t vlen = total - nlen - 1;
            size_t i;
            if (nlen >= sizeof(name))
                return size * nmemb;
            memcpy(name, line, nlen);
            for (i = 0; i < nlen; i++) {
                if (name[i] >= 'A' && name[i] <= 'Z')
                    name[i] = (char)(name[i] - 'A' + 'a');
            }
            while (vlen > 0 && (*val == ' ' || *val == '\t')) { val++; vlen--; }
            while (vlen > 0 && (val[vlen - 1] == ' ' || val[vlen - 1] == '\t'))
                vlen--;
            hdrs_append(h, name, nlen);
            hdrs_append(h, ": ", 2);
            hdrs_append(h, val, vlen);
            hdrs_append(h, "\n", 1);
        }
    }
    return size * nmemb;
}

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

/* http_req(opts) -> body, status, headers | nil, err
 *   opts: { url=, method="GET"|"POST", headers={["Name"]="value",...},
 *           body="..."（POST 时）, timeout=秒（默认 30） }
 *   headers 返回小写名 → 值；同名头用 "\n" 连接（Set-Cookie 多值）。 */
static int l_http_req(lua_State *L)
{
    const char *url, *method;
    const char *body = NULL;
    size_t body_len = 0;
    int timeout = WR_TIMEOUT_S;
    CURL *c;
    struct wr_body b = { NULL, 0, 0 };
    struct wr_hdrs h = { NULL, 0, 0 };
    struct curl_slist *hdr_list = NULL;
    char errbuf[CURL_ERROR_SIZE];
    int rc;
    long status = 0;

    luaL_checktype(L, 1, LUA_TTABLE);
    lua_getfield(L, 1, "url");
    url = luaL_checkstring(L, -1);
    lua_getfield(L, 1, "method");
    method = lua_isstring(L, -1) ? lua_tostring(L, -1) : "GET";
    lua_getfield(L, 1, "body");
    if (lua_isstring(L, -1))
        body = lua_tolstring(L, -1, &body_len);
    lua_getfield(L, 1, "timeout");
    if (lua_isnumber(L, -1) && lua_tointeger(L, -1) > 0)
        timeout = (int)lua_tointeger(L, -1);
    lua_getfield(L, 1, "headers");
    if (lua_istable(L, -1)) {
        lua_pushnil(L);
        while (lua_next(L, -2) != 0) {
            if (lua_isstring(L, -2) && lua_isstring(L, -1)) {
                /* 按实际长度堆分配，避免长 Cookie/Authorization 头被定长
                 * 缓冲静默截断（截断会导致鉴权失败且无线索）。
                 * curl_slist_append 内部拷贝字符串，故 append 后即可 free。 */
                size_t klen, vlen;
                const char *key = lua_tolstring(L, -2, &klen);
                const char *value = lua_tolstring(L, -1, &vlen);
                char *item = malloc(klen + vlen + 3);  /* "key: value\0" */
                if (item) {
                    memcpy(item, key, klen);
                    item[klen] = ':';
                    item[klen + 1] = ' ';
                    memcpy(item + klen + 2, value, vlen);
                    item[klen + vlen + 2] = '\0';
                    hdr_list = curl_slist_append(hdr_list, item);
                    free(item);
                }
            }
            lua_pop(L, 1);
        }
    }

    c = curl_easy_init();
    if (!c) {
        curl_slist_free_all(hdr_list);
        lua_pushnil(L); lua_pushstring(L, "curl_easy_init failed");
        return 2;
    }

    memset(errbuf, 0, sizeof(errbuf));
    curl_easy_setopt(c, CURLOPT_URL, url);
    curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, method);
    if (body)
        curl_easy_setopt(c, CURLOPT_POSTFIELDS, body);
    curl_easy_setopt(c, CURLOPT_POSTFIELDSIZE, (long)body_len);
    if (hdr_list)
        curl_easy_setopt(c, CURLOPT_HTTPHEADER, hdr_list);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, on_body);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &b);
    curl_easy_setopt(c, CURLOPT_HEADERFUNCTION, on_header);
    curl_easy_setopt(c, CURLOPT_HEADERDATA, &h);
    curl_easy_setopt(c, CURLOPT_ERRORBUFFER, errbuf);
    curl_easy_setopt(c, CURLOPT_CAINFO, WR_DEFAULT_CA);
    curl_easy_setopt(c, CURLOPT_SSL_VERIFYPEER, 1L);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, (long)timeout);
    curl_easy_setopt(c, CURLOPT_USERAGENT, "WereadK4/0.1");
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);

    rc = curl_easy_perform(c);
    if (rc == CURLE_OK)
        curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
    curl_easy_cleanup(c);
    curl_slist_free_all(hdr_list);

    if (rc != CURLE_OK) {
        free(b.buf);
        free(h.buf);
        lua_pushnil(L);
        lua_pushfstring(L, "curl rc=%d: %s", rc,
                        errbuf[0] ? errbuf : curl_easy_strerror(rc));
        return 2;
    }

    lua_pushlstring(L, b.buf ? b.buf : "", b.len);
    free(b.buf);
    lua_pushinteger(L, (lua_Integer)status);

    /* headers 表：按 "\n" 行 split，"name: value"（name 已小写） */
    lua_newtable(L);
    if (h.buf) {
        char *p = h.buf;
        while (*p) {
            char *eol = strchr(p, '\n');
            size_t n = eol ? (size_t)(eol - p) : strlen(p);
            char *colon = memchr(p, ':', n);
            if (colon && colon != p) {
                size_t nlen = (size_t)(colon - p);
                const char *val = colon + 1;
                size_t vlen = n - nlen - 1;
                while (vlen > 0 && (*val == ' ')) { val++; vlen--; }
                lua_pushlstring(L, p, nlen);      /* key */
                lua_gettable(L, -2);              /* 旧值（同名头追加语义） */
                if (lua_isnil(L, -1)) {
                    lua_pop(L, 1);
                    lua_pushlstring(L, val, vlen);
                } else {
                    lua_pushlstring(L, "\n", 1);
                    lua_pushlstring(L, val, vlen);
                    lua_concat(L, 3);             /* old .. "\n" .. val */
                }
                lua_pushlstring(L, p, nlen);      /* key */
                lua_settable(L, -3);
            }
            if (!eol)
                break;
            p = eol + 1;
        }
        free(h.buf);
    }
    return 3;
}

static const luaL_Reg net_funcs[] = {
    { "http_get", l_http_get },
    { "http_req", l_http_req },
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
