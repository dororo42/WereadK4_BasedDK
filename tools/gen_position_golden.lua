-- gen_position_golden.lua — 用参照实现（weread_K4.koplugin 的 position_mapper）重生成
-- tests/position_golden_vectors.lua。期望值必须由**参照实现**算出来，不是我手算，
-- 差分测试才有意义。仓库根目录执行；插件不在默认路径时用 PLUGIN_WEREAD=... 指过去。
local plugin = os.getenv("PLUGIN_WEREAD") or "/home/doro/weread_K4.koplugin"
package.path = plugin .. "/weread/lib/?.lua;" .. package.path
if not (io.open(plugin .. "/weread/lib/position_mapper.lua", "r")) then
    print("找不到参照实现：" .. plugin .. "/weread/lib/position_mapper.lua\n用 PLUGIN_WEREAD=... lua5.1 tools/gen_position_golden.lua 指到插件目录")
    os.exit(1)
end
local Mapper = require("position_mapper")

local function cat(uid0, idxs, words)
    local out = {}
    for i, w in ipairs(words) do
        out[#out + 1] = { chapterUid = uid0 + i - 1, chapterIdx = idxs[i], title = "c" .. i, wordCount = w }
    end
    return out
end

local catalogs = {
    { name = "varied_12", c = cat(1001, { 1,2,3,4,5,6,7,8,9,10,11,12 },
        { 1180, 2260, 940, 4180, 1655, 3020, 880, 2745, 1990, 340, 5120, 1775 }) },
    { name = "zero_front_matter", c = cat(2001, { 0,1,2,3,4,5 },
        { 0, 1240, 2380, 0, 1560, 3010 }) },
    { name = "big_final", c = cat(3001, { 1,2,3 }, { 420, 610, 98500 }) },
    { name = "placeholder", c = cat(4001, { 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20 },
        { 4,1,3,2,1,4,2,3,1,2,4,1,3,2,1,4,2,3,1,2 }) },
}

local out = {}
out[#out + 1] = "-- position_golden_vectors.lua — 参照实现产出的期望值（生成物，勿手改）。"
out[#out + 1] = "-- 生成：PLUGIN_WEREAD=<插件目录> lua5.1 tools/gen_position_golden.lua（仓库根目录执行）"
out[#out + 1] = "--   基准 = 插件 weread/lib/position_mapper.lua 的 local_to_remote(chapters, fraction, {current_chapter_uid=…})，"
out[#out + 1] = "--   非本仓手写算术。fraction 用本仓的页码映射 (page-1)/total_pages 喂进去，"
out[#out + 1] = "--   于是本文件钉的是「字数 → (章内偏移, 全书百分比)」这段跨客户端约定本身。"
out[#out + 1] = "-- words>0 的行 = 参照实现认可、本仓必须逐字节一致；"
out[#out + 1] = "-- plugin_refused 的行 = 参照实现对 words<=0 直接报错，本仓刻意继续（三类行的判据见 tests/position_golden_test.lua 头注释）。"
out[#out + 1] = "return {"
out[#out + 1] = "  catalogs = {"
for ci, item in ipairs(catalogs) do
    local parts = {}
    for _, ch in ipairs(item.c) do
        parts[#parts + 1] = string.format("{chapterUid=%d,chapterIdx=%d,wordCount=%d},",
            ch.chapterUid, ch.chapterIdx, ch.wordCount)
    end
    out[#out + 1] = string.format("    [%d] = { name = %q, chapters = { %s } },", ci, item.name, table.concat(parts, " "))
end
out[#out + 1] = "  },"
out[#out + 1] = "  vectors = {"
local nvec, ndiv = 0, 0
for ci, item in ipairs(catalogs) do
    for pos, ch in ipairs(item.c) do
        local grids = item.name == "placeholder" and { { 10, { 1, 5, 10 } } } or { { 7, nil }, { 10, nil } }
        for _, g in ipairs(grids) do
            local tp = g[1]
            for _, page in ipairs(g[2] or (function() local t = {} for i = 1, tp do t[i] = i end return t end)()) do
                local fraction = (page - 1) / tp
                local r, err = Mapper.local_to_remote(item.c, fraction,
                    { current_chapter_uid = ch.chapterUid })
                if r then
                    nvec = nvec + 1
                    out[#out + 1] = string.format(
                        "    { cat = %d, idx = %d, page = %d, tp = %d, off = %d, pct = %d },",
                        ci, ch.chapterIdx, page, tp, r.chapter_offset, r.percent)
                else
                    ndiv = ndiv + 1
                    out[#out + 1] = string.format(
                        "    { cat = %d, idx = %d, page = %d, tp = %d, plugin_refused = %q },",
                        ci, ch.chapterIdx, page, tp, tostring(err))
                end
            end
        end
    end
end
out[#out + 1] = "  },"
out[#out + 1] = string.format("  -- generated: %d agreement vector(s), %d plugin-refused vector(s)", nvec, ndiv)
out[#out + 1] = "}"
local f = io.open("/home/doro/WereadK4_BasedDK/tests/position_golden_vectors.lua", "w")
f:write(table.concat(out, "\n") .. "\n")
f:close()
print(string.format("golden: %d agree, %d plugin_refused", nvec, ndiv))
