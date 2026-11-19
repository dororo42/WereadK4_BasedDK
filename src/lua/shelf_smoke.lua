-- shelf_smoke.lua — 书架视图冒烟驱动：SMOKE 渲染一帧+像素自检退出。
package.path = "/mnt/us/weread/lua/lib/?.lua;/mnt/us/weread/lua/?.lua;" .. package.path
local Shelf = require("shelf")
assert(wr.fb_open(), "fb_open failed")
assert(wr.input_open(), "input_open failed")
Shelf.run()
wr.input_close()
wr.fb_close()
print("shelf smoke done")
