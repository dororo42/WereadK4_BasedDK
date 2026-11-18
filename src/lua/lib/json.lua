-- json.lua — 自研紧凑 JSON 编解码（Lua 5.1 / LuaJIT 兼容）。
-- decode(text) -> value | nil, err
-- encode(value) -> string
-- 数字统一 double（weread id 在 1e10 内，53bit 精度安全）。

local Json = {}
local type = type
local sub, find, gsub = string.sub, string.find, string.gsub

------------------------------------------------------------------ encode

local escapes = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encode_string(s)
    return '"' .. gsub(s, '[%c"\\]', function(ch)
        return escapes[ch] or string.format("\\u%04x", ch:byte())
    end) .. '"'
end

local function is_array(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n == #t
end

local function encode_value(v, buf)
    local tv = type(v)
    if v == nil then
        buf[#buf + 1] = "null"
    elseif tv == "boolean" then
        buf[#buf + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v == math.floor(v) and math.abs(v) < 2^53 then
            buf[#buf + 1] = string.format("%d", v)
        else
            buf[#buf + 1] = string.format("%.14g", v)
        end
    elseif tv == "string" then
        buf[#buf + 1] = encode_string(v)
    elseif tv == "table" then
        if is_array(v) then
            buf[#buf + 1] = "["
            for i = 1, #v do
                if i > 1 then buf[#buf + 1] = "," end
                encode_value(v[i], buf)
            end
            buf[#buf + 1] = "]"
        else
            buf[#buf + 1] = "{"
            local first = true
            for k, val in pairs(v) do
                if not first then buf[#buf + 1] = "," end
                first = false
                buf[#buf + 1] = encode_string(tostring(k))
                buf[#buf + 1] = ":"
                encode_value(val, buf)
            end
            buf[#buf + 1] = "}"
        end
    else
        error("json.encode: unsupported type " .. tv)
    end
end

function Json.encode(v)
    local buf = {}
    encode_value(v, buf)
    return table.concat(buf)
end

------------------------------------------------------------------ decode

local Parser = {}
Parser.__index = Parser

function Parser.new(text)
    return setmetatable({ s = text, i = 1, n = #text }, Parser)
end

function Parser:skip_ws()
    local _, e = find(self.s, "^[ \t\r\n]*", self.i)
    self.i = e + 1
end

function Parser:peek()
    self:skip_ws()
    return sub(self.s, self.i, self.i)
end

function Parser:value()
    local ch = self:peek()
    if ch == "{" then return self:object()
    elseif ch == "[" then return self:array()
    elseif ch == '"' then return self:str()
    elseif ch == "t" then return self:lit("true", true)
    elseif ch == "f" then return self:lit("false", false)
    elseif ch == "n" then return self:lit("null", nil)
    elseif ch == "-" or (ch >= "0" and ch <= "9") then return self:num()
    else
        return nil, "json.decode: unexpected char at " .. self.i
    end
end

function Parser:lit(word, val)
    if sub(self.s, self.i, self.i + #word - 1) ~= word then
        return nil, "json.decode: bad literal at " .. self.i
    end
    self.i = self.i + #word
    return val
end

function Parser:num()
    local _, e, num = find(self.s, "^-?%d+%.?%d*[eE]?[+-]?%d*", self.i)
    if not e or e < self.i then
        return nil, "json.decode: bad number at " .. self.i
    end
    self.i = e + 1
    return tonumber(num)
end

function Parser:str()
    self.i = self.i + 1                          -- 跳过开头 "
    local out = {}
    while self.i <= self.n do
        local ch = sub(self.s, self.i, self.i)
        if ch == '"' then
            self.i = self.i + 1
            return table.concat(out)
        elseif ch == "\\" then
            local esc = sub(self.s, self.i + 1, self.i + 1)
            self.i = self.i + 2
            local simple = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
            if simple[esc] then
                out[#out + 1] = simple[esc]
            elseif esc == "u" then
                local hex = sub(self.s, self.i, self.i + 3)
                self.i = self.i + 4
                local cp = tonumber(hex, 16)
                if not cp then return nil, "json.decode: bad \\u escape" end
                -- 代理对 → UTF-8（基础多平面；代理对合并后重编码）
                if cp >= 0xD800 and cp <= 0xDBFF
                    and sub(self.s, self.i, self.i + 1) == "\\u" then
                    local lo = tonumber(sub(self.s, self.i + 2, self.i + 5), 16)
                    if lo and lo >= 0xDC00 and lo <= 0xDFFF then
                        self.i = self.i + 6
                        cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
                    end
                end
                if cp < 0x80 then
                    out[#out + 1] = string.char(cp)
                elseif cp < 0x800 then
                    out[#out + 1] = string.char(0xC0 + math.floor(cp / 64), 0x80 + cp % 64)
                elseif cp < 0x10000 then
                    out[#out + 1] = string.char(0xE0 + math.floor(cp / 4096),
                        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
                else
                    out[#out + 1] = string.char(0xF0 + math.floor(cp / 262144),
                        0x80 + math.floor(cp / 4096) % 64,
                        0x80 + math.floor(cp / 64) % 64, 0x80 + cp % 64)
                end
            else
                out[#out + 1] = esc
            end
        else
            out[#out + 1] = ch
            self.i = self.i + 1
        end
    end
    return nil, "json.decode: unterminated string"
end

function Parser:object()
    self.i = self.i + 1
    local t = {}
    if self:peek() == "}" then
        self.i = self.i + 1
        return t
    end
    while true do
        local ch = self:peek()
        if ch ~= '"' then
            return nil, "json.decode: expected key at " .. self.i
        end
        local key = self:str()
        if key == nil then return nil, key end
        if self:peek() ~= ":" then
            return nil, "json.decode: expected : at " .. self.i
        end
        self.i = self.i + 1
        local val, err = self:value()
        if val == nil and err then return nil, err end
        t[key] = val
        ch = self:peek()
        if ch == "," then
            self.i = self.i + 1
        elseif ch == "}" then
            self.i = self.i + 1
            return t
        else
            return nil, "json.decode: expected , or } at " .. self.i
        end
    end
end

function Parser:array()
    self.i = self.i + 1
    local t = {}
    if self:peek() == "]" then
        self.i = self.i + 1
        return t
    end
    while true do
        local val, err = self:value()
        if val == nil and err then return nil, err end
        t[#t + 1] = val
        local ch = self:peek()
        if ch == "," then
            self.i = self.i + 1
        elseif ch == "]" then
            self.i = self.i + 1
            return t
        else
            return nil, "json.decode: expected , or ] at " .. self.i
        end
    end
end

function Json.decode(text)
    if type(text) ~= "string" or text == "" then
        return nil, "json.decode: empty input"
    end
    local p = Parser.new(text)
    local val, err = p:value()
    if err then return nil, err end
    p:skip_ws()
    if p.i <= p.n then
        return nil, "json.decode: trailing content at " .. p.i
    end
    return val
end

return Json
