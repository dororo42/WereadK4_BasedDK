-- shelf_recent_test.lua — 极简书架排序回归：readUpdateTime 降序、0/缺失排最后、前 10 裁剪。
package.path = "src/lua/lib/?.lua;src/lua/?.lua;tests/?.lua;" .. package.path
local Shelf = require("shelf")

local fails = 0
local function check(name, ok, detail)
    print((ok and "PASS " or "FAIL ") .. name .. (detail and ("  " .. detail) or ""))
    if not ok then fails = fails + 1 end
end

-- 1) 降序排序
local books = {
    { title = "旧A", readUpdateTime = 100 },
    { title = "新C", readUpdateTime = 300 },
    { title = "中B", readUpdateTime = 200 },
}
local sorted = Shelf.by_recent(books)
check("sort.desc", sorted[1].title == "新C" and sorted[2].title == "中B" and sorted[3].title == "旧A")

-- 2) 0/缺失时间戳排最后（从未读过）
local books2 = {
    { title = "无记录", readUpdateTime = nil },
    { title = "读过", readUpdateTime = 500 },
    { title = "零", readUpdateTime = 0 },
}
local sorted2 = Shelf.by_recent(books2)
check("sort.missing_last", sorted2[1].title == "读过" and sorted2[3].title == "零")

-- 3) 不改原数组（纯函数）
check("sort.pure", books[1].title == "旧A")

-- 4) 前十裁剪（12 本 → 10）
local many = {}
for i = 1, 12 do many[i] = { title = "b" .. i, readUpdateTime = i } end
local sorted3 = Shelf.by_recent(many)
check("sort.count_all", #sorted3 == 12)
-- 裁剪在调用方（Shelf.run 内 min(10)）——这里验证排序后的前 10 确是最新 10 本
check("sort.top10_recency", sorted3[12].title == "b1" and sorted3[3].title == "b10")

print(string.format("shelf_recent_test done: %s (fails=%d)",
      fails == 0 and "ALL PASS" or "HAS FAILURES", fails))
return fails
