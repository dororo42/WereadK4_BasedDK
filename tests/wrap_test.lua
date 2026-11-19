-- wrap_test.lua — 折行回归：reader.wrap_line 的 UTF-8 安全性（中文多行不切字）。
--
-- 背景（code review 🔴）：原实现 pos 按字节推进、fit 按字符计数，中文行超宽时
-- 会切进多字节字符中间。修复后 wrap_line 在字符域工作，测量函数依赖注入，
-- 主机侧用假 measure 测（不依赖设备 fb/freetype）。
package.path = "src/lua/lib/?.lua;src/lua/?.lua;tests/?.lua;" .. package.path
local Reader = require("reader")

local fails = 0
local function check(name, ok, detail)
    print((ok and "PASS " or "FAIL ") .. name .. (detail and ("  " .. detail) or ""))
    if not ok then fails = fails + 1 end
end

-- 等宽假测量：每字符 10px（整串宽度 = 10 × 字符数，与真字体 measure 语义一致）
local function ulen(s)
    local n, i = 0, 1
    while i <= #s do
        local b = s:byte(i)
        local w = (b >= 0xF0 and 4) or (b >= 0xE0 and 3) or (b >= 0xC2 and 2) or 1
        i = i + w
        n = n + 1
    end
    return n
end
local mono10 = function(s) return 10 * ulen(s) end

-- 1) 中文长行超宽 → 多行，且**每行重新拼接 == 原行**（无字符丢失/重复/乱码）
do
    local line = "微信读书K4阅读器的折行逻辑测试"        -- 15 字符（混合中英）
    local rows = Reader.wrap_line(mono10, 100, line)    -- 每行最多 10 字符
    local joined = table.concat(rows, "")
    check("wrap.roundtrip", joined == line, "rows=" .. #rows)
end

-- 2) 每字符 10px、maxw 20 → 每行 2 字符，绝不产生半字
do
    local line = "测试折行"
    local rows = Reader.wrap_line(mono10, 20, line)
    local joined = table.concat(rows, "")
    check("wrap.cjk_multirow", joined == line and #rows == 2,
          "rows=" .. #rows .. " joined=" .. joined)
    for i, r in ipairs(rows) do
        check("wrap.row" .. i .. ".utf8safe", r == "测试" or r == "折行", "row=" .. r)
    end
end

-- 3) 超宽单字符（测量 > maxw）也必须出现在输出里（不死循环、不丢字）
do
    local line = "宽A窄"
    local wide = function(s) return (s:byte(1) or 0) >= 0xE0 and 999 or 10 end
    local rows = Reader.wrap_line(wide, 20, line)
    local joined = table.concat(rows, "")
    check("wrap.wide_char_no_loop", joined == line, "rows=" .. #rows)
end

-- 4) 空行 / 单字符边界
do
    check("wrap.empty", #Reader.wrap_line(mono10, 100, "") == 0)
    check("wrap.single", Reader.wrap_line(mono10, 10, "中")[1] == "中")
end

-- 5) 混合宽度（假比例字体：CJK 20px / ASCII 10px）行拼接不变
do
    local line = "K4阅读器分页"
    local mixed = function(s)
        local w = 0
        for _, b in ipairs({ s:byte(1, #s) }) do
            w = w + (b >= 0xE0 and 20 or 10)
        end
        return w
    end
    local rows = Reader.wrap_line(mixed, 60, line)
    check("wrap.mixed_width", table.concat(rows, "") == line, "rows=" .. #rows)
end

print(string.format("wrap_test done: %s (fails=%d)",
      fails == 0 and "ALL PASS" or "HAS FAILURES", fails))
return fails   -- run.lua 契约：返回失败计数（独立运行时 number 即退出码）
