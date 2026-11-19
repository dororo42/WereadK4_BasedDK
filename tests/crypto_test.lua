-- crypto.lua 已知答案测试（known-answer）：MD5/SHA-256 必须等于公开标准向量。
--
-- 为什么单独一套：`WeRead.sign()` 与整条上报/取正文的签名面（protocol.lua）建在这两个摘要上。
-- 摘要错了不会崩，只会**被服务端拒绝**——而插件与本仓 protocol.lua 逐字节相同（diff 只有注释），
-- 所以拿插件做差分在这条路上一文不值（证明的是同一份代码等于它自己）。
-- 唯一有信息量的基准是标准本身：期望值取自 RFC 1321 A.7 测试套件与 NIST FIPS 180-2 向量，
-- 本机 `md5sum`/`sha256sum`（GNU coreutils）对同一样例逐个复核过（2026-11-19）。
--
-- 边界刻意挑在填充点上：63/64/65（MD5 一个 block 的边界）、119/120（SHA-256 长度字段从
-- 1 字节区跨到 2 字节区）、256 全字节（高低位混合、含 NUL 与控制字符）、CJK（多字节）。
-- 1e6 字节的样例只在主机跑（纯 Lua 在 K4 上太慢，见 slow 标记）：它验的是长度字段的
-- 64-bit 拼接，短样例碰不到。
local Crypto = require("crypto")

local vectors = {
    { name = "empty", input = "", len = 0,
      md5 = "d41d8cd98f00b204e9800998ecf8427e",
      sha256 = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
    { name = "abc", input = "abc", len = 3,
      md5 = "900150983cd24fb0d6963f7d28e17f72",
      sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
    { name = "quick_fox", input = "The quick brown fox jumps over the lazy dog", len = 43,
      md5 = "9e107d9d372bb6826bd81d3542a419d6",
      sha256 = "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592" },
    { name = "a_63", input = string.rep("a", 63), len = 63,
      md5 = "b06521f39153d618550606be297466d5",
      sha256 = "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34" },
    { name = "a_64", input = string.rep("a", 64), len = 64,
      md5 = "014842d480b571495a4a0363793f7367",
      sha256 = "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb" },
    { name = "a_65", input = string.rep("a", 65), len = 65,
      md5 = "c743a45e0d2e6a95cb859adae0248435",
      sha256 = "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0" },
    { name = "a_119", input = string.rep("a", 119), len = 119,
      md5 = "8a7bd0732ed6a28ce75f6dabc90e1613",
      sha256 = "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb" },
    { name = "a_120", input = string.rep("a", 120), len = 120,
      md5 = "5f61c0ccad4cac44c75ff505e1f1e537",
      sha256 = "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c" },
    { name = "a_1000", input = string.rep("a", 1000), len = 1000,
      md5 = "cabe45dcc9ae5b66ba86600cca6b8ba8",
      sha256 = "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3" },
    { name = "cjk", input = "微信读书", len = 12,
      md5 = "664b5d039b78fe3d81097e9977924823",
      sha256 = "987dccf2ea2b28cc25cfa87ead5e9d9320b8dcccebdbfacf326559ed2c0941a0" },
    { name = "all_bytes",
      input = "\000\001\002\003\004\005\006\007\008\009\010\011\012\013\014\015"
           .. "\016\017\018\019\020\021\022\023\024\025\026\027\028\029\030\031"
           .. "\032\033\034\035\036\037\038\039\040\041\042\043\044\045\046\047"
           .. "\048\049\050\051\052\053\054\055\056\057\058\059\060\061\062\063"
           .. "\064\065\066\067\068\069\070\071\072\073\074\075\076\077\078\079"
           .. "\080\081\082\083\084\085\086\087\088\089\090\091\092\093\094\095"
           .. "\096\097\098\099\100\101\102\103\104\105\106\107\108\109\110\111"
           .. "\112\113\114\115\116\117\118\119\120\121\122\123\124\125\126\127"
           .. "\128\129\130\131\132\133\134\135\136\137\138\139\140\141\142\143"
           .. "\144\145\146\147\148\149\150\151\152\153\154\155\156\157\158\159"
           .. "\160\161\162\163\164\165\166\167\168\169\170\171\172\173\174\175"
           .. "\176\177\178\179\180\181\182\183\184\185\186\187\188\189\190\191"
           .. "\192\193\194\195\196\197\198\199\200\201\202\203\204\205\206\207"
           .. "\208\209\210\211\212\213\214\215\216\217\218\219\220\221\222\223"
           .. "\224\225\226\227\228\229\230\231\232\233\234\235\236\237\238\239"
           .. "\240\241\242\243\244\245\246\247\248\249\250\251\252\253\254\255",
      len = 256,
      md5 = "e2c865db4162bed963bfaa9ef6ac18f0",
      sha256 = "40aff2e9d2d8922e47afd4648e6967497158785fbd1da870e7110266bf944880" },
    { name = "a_1e6", input = string.rep("a", 1000000), len = 1000000, slow = true,
      md5 = "7707d6ae4e027c70eea2a935c2296f21",
      sha256 = "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0" },
}

local fails, checked, skipped = 0, 0, 0
local slow_wanted = os.getenv("WR_CRYPTO_SLOW") == "1"

for _, v in ipairs(vectors) do
    if v.slow and not slow_wanted then
        skipped = skipped + 1
    else
        -- 样例自身也要自证：输入长度不对，期望值就没有意义
        if #v.input ~= v.len then
            print("FAIL crypto: 样例 " .. v.name .. " 长度不符 " .. #v.input .. " != " .. v.len)
            fails = fails + 1
        end
        local m = Crypto.md5_hex(v.input)
        if m ~= v.md5 then
            print("FAIL crypto md5 " .. v.name .. "(" .. v.len .. "B): 期望 " .. v.md5
                .. " 实得 " .. tostring(m))
            fails = fails + 1
        end
        local s = Crypto.sha256_hex(v.input)
        if s ~= v.sha256 then
            print("FAIL crypto sha256 " .. v.name .. "(" .. v.len .. "B): 期望 " .. v.sha256
                .. " 实得 " .. tostring(s))
            fails = fails + 1
        end
        checked = checked + 1
    end
end

-- 摘要必须是 32 / 64 位小写十六进制；长度错了说明返回了截断或二进制
local function hex_shape(str, want)
    return type(str) == "string" and #str == want and str:find("[^0-9a-f]") == nil
end
if not hex_shape(Crypto.md5_hex("x"), 32) then
    print("FAIL crypto: md5_hex 返回不是 32 位小写 hex")
    fails = fails + 1
end
if not hex_shape(Crypto.sha256_hex("x"), 64) then
    print("FAIL crypto: sha256_hex 返回不是 64 位小写 hex")
    fails = fails + 1
end

print(string.format("crypto: %d 样例 ×2 摘要，跳过 %d（slow；WR_CRYPTO_SLOW=1 打开）",
    checked, skipped))
return fails
