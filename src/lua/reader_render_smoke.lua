-- reader_render_smoke.lua — 🔴折行修复的真机渲染验证：
-- 真实章节文本 → Reader.layout（真 freetype 测量）→ 回环校验 + 首页像素自检。
-- 用法: ./weread-dyn lua/reader_render_smoke.lua [bookId] [chapterIdx]
package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path

-- arg 表语义（wrmain）：arg[0]=script 路径，数组部分含脚本路径本身——
-- 逐项收集"纯数字且长度>=3"的项，第一个为 bookId，第二个为 chapterIdx。
local book_id, ch_idx = "3300235630", 3
do
    local ordered = {}
    if arg then
        for i = 0, 9 do
            local a = arg[i]
            if a and a:match("^%d+$") and #a >= 3 then
                ordered[#ordered + 1] = a
            end
        end
    end
    if ordered[1] then book_id = ordered[1] end
    if ordered[2] then ch_idx = tonumber(ordered[2]) or 3 end
end

local path = string.format("/mnt/us/weread/books/%s/%03d.txt", book_id, ch_idx)
local f = io.open(path, "r")
assert(f, "spool missing: " .. path)
local raw = f:read("*a")
f:close()
local title = raw:match("^(.-)\n") or ""
local body = raw:match("^.-\n\n(.*)$") or raw

assert(wr.fb_open(), "fb_open failed")
local ft = wr.font_load("/mnt/us/weread/fonts/wqy-microhei.ttc", 26)
assert(ft, "font load failed")

local Reader = require("reader")
local W, H = wr.fb_w(), wr.fb_h()
local rows = Reader.layout(ft, W - 60, body)

-- 回环校验（布局不变式）：折行/trim 只改空白布局，**非空白字符序列必须完全一致**。
-- （逐行 trim 的比对会把"恰跨折行边界的行中 tab"误判为丢失——假阳性已实证。）
local function nospace(t)
    return (t:gsub("%s", ""))
end
local joined = nospace(table.concat(rows, ""))
local original = nospace(body)
print(string.format("layout: rows=%d roundtrip=%s", #rows,
      joined == original and "OK" or "MISMATCH"))
if joined ~= original then
    for i = 1, math.min(#joined, #original) do
        if joined:byte(i) ~= original:byte(i) then
            print(string.format("first diff at byte %d: got[%s] want[%s]",
                  i, joined:sub(i, i + 8), original:sub(i, i + 8)))
            break
        end
    end
end

-- 渲染首页 + 像素自检（正文区应有黑笔画；页脚灰字）
wr.fb_fill(0, 0, W, H, 0xFF)
local y = 24
for i = 1, math.min(#rows, 18) do
    if rows[i] ~= "" then
        wr.fb_text_ft(ft, 30, y, rows[i], 0x00)
    end
    y = y + 40
end
wr.fb_quant()
wr.fb_refresh(0)

local dark = 255
for yy = 24, 700 do
    for xx = 30, 570 do
        local v = wr.fb_get(xx, yy)
        if v >= 0 and v < dark then dark = v end
    end
end
print("pixel-check body-min=" .. tostring(dark) .. " (0=黑笔画 PASS)")
wr.font_close(ft)
wr.fb_close()
local fails = (joined ~= original and 1 or 0) + (dark > 200 and 1 or 0)
print(string.format("reader render smoke: %s (fails=%d)",
      fails == 0 and "ALL PASS" or "HAS FAILURES", fails))
os.exit(fails == 0 and 0 or 1)
