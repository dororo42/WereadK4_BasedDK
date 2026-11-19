-- shard.lua — 微信读书章节内容分片解码器。
-- 移植自 weread_K4.koplugin weread/lib/content.lua（checked_body/swap_positions/
-- reverse_swaps/base64_decode 纯 Lua 分支，仅去除 FFI 路径——本仓静态 exe 无动态符号）。
-- 分片格式：前 32 字符 = 正文大写 MD5，其后为字符换位+URL-safe base64 编码的正文。

local Crypto = require("crypto")

local Shard = {}

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local b64_decode_table
local b64_pad_table

local function init_b64_decode_table()
    if b64_decode_table then return end
    b64_decode_table = {}
    b64_pad_table = {}
    for i = 0, 63 do
        local code = b64chars:byte(i + 1)
        b64_decode_table[code] = i
    end
    b64_pad_table[string.byte("=")] = true
end

local function b64_decode_chunked(data, len)
    local result = {}
    local chunk = {}
    local chunk_len = 0
    local i = 1
    local t = b64_decode_table
    while i <= len - 3 do
        local a, b, c, d = data:byte(i, i + 3)
        local av, bv = t[a], t[b]
        if av and bv then
            chunk[chunk_len + 1] = string.char(av * 4 + math.floor(bv / 16))
            chunk_len = chunk_len + 1
            local cv = c and t[c]
            if cv and not b64_pad_table[c] then
                chunk[chunk_len + 1] = string.char((bv % 16) * 16 + math.floor(cv / 4))
                chunk_len = chunk_len + 1
                local dv = d and t[d]
                if dv and not b64_pad_table[d] then
                    chunk[chunk_len + 1] = string.char((cv % 4) * 64 + dv)
                    chunk_len = chunk_len + 1
                end
            end
        end
        i = i + 4
        if chunk_len >= 65536 then
            result[#result + 1] = table.concat(chunk)
            chunk = {}
            chunk_len = 0
        end
    end
    if chunk_len > 0 then
        result[#result + 1] = table.concat(chunk)
    end
    return table.concat(result)
end

local function base64_decode(data)
    data = data:gsub("-", "+"):gsub("_", "/")
    local pad = #data % 4
    if pad > 0 then
        data = data .. string.rep("=", 4 - pad)
    end
    data = data:gsub("[^" .. b64chars .. "=]", "")
    init_b64_decode_table()
    return b64_decode_chunked(data, #data)
end

local function swap_positions(encoded)
    local length = #encoded
    if length < 4 then
        return {}
    end
    if length < 11 then
        return { 0, 2 }
    end

    local n = math.min(4, math.floor((length + 9) / 10))
    local tmp = {}
    for i = length, length - n + 1, -1 do
        local byte = encoded:byte(i)
        local bin = {}
        repeat
            table.insert(bin, 1, tostring(byte % 2))
            byte = math.floor(byte / 2)
        until byte == 0
        local value = tonumber(table.concat(bin), 4) or 0
        table.insert(tmp, tostring(value))
    end
    tmp = table.concat(tmp)

    local result = {}
    local m = length - n - 2
    local step = #tostring(m)
    local i = 1
    while #result < 10 and i + step - 1 < #tmp do
        table.insert(result, (tonumber(tmp:sub(i, i + step - 1)) or 0) % m)
        local end2 = math.min(i + step, #tmp)
        if i + 1 <= #tmp then
            table.insert(result, (tonumber(tmp:sub(i + 1, end2)) or 0) % m)
        end
        i = i + step
    end
    return result
end

local function reverse_swaps(encoded, positions)
    -- 换位以 (positions[i], positions[i-1]) 成对消费，步长 -2；奇数个会在
    -- i=1 时读到 positions[0]=nil → 对 nil 做算术崩溃。swap_positions 在 tmp
    -- 于奇数位耗尽时可能返回奇数个，故在此显式 fail-fast（Shard.decode 已被
    -- download.lua pcall，异常会转成干净的解码失败而非崩溃）。
    if #positions % 2 ~= 0 then
        error("shard: odd swap-position count (" .. #positions .. ")")
    end
    local chars = {}
    for i = 1, #encoded do
        chars[i] = encoded:sub(i, i)
    end
    for i = #positions, 1, -2 do
        for k = 1, 0, -1 do
            local left = positions[i] + k + 1
            local right = positions[i - 1] + k + 1
            chars[left], chars[right] = chars[right], chars[left]
        end
    end
    return table.concat(chars)
end

-- 校验 + 解码单个分片响应文本
function Shard.decode(response_text)
    if not response_text or #response_text <= 32 then
        return ""
    end
    local expected = response_text:sub(1, 32)
    local body = response_text:sub(33)
    local actual = Crypto.md5_hex(body):upper()
    if actual ~= expected then
        error("Shard MD5 mismatch")
    end
    local encoded = body:sub(2)
    local restored = reverse_swaps(encoded, swap_positions(encoded))
    return base64_decode(restored)
end

return Shard
