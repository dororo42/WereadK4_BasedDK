-- shelf_smoke.lua — 书架视图冒烟驱动：SMOKE 渲染一帧+像素自检退出。
package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path
local Shelf = require("shelf")
assert(wr.fb_open(), "fb_open failed")
assert(wr.input_open(), "input_open failed")
local _, why = Shelf.run()
wr.input_close()
wr.fb_close()
-- SMOKE 分支把本帧行数带回来说 "smoke done, shown=N books=M"：分页契约（一页只画
-- 10 行，而不是把 10187 本全画出去）在真机上只有这一个可断言的量。
local shown = tonumber((why or ""):match("shown=(%d+)"))
print("shelf smoke done :: " .. tostring(why))
if shown ~= 10 then
    print("SHELF-ROWS-FAIL 应画 10 行，实得 " .. tostring(shown))
    os.exit(1)
end
print("SHELF-ROWS-PASS")
