#!/bin/sh
# tools/mut-assets.sh — download.lua 图片资产链路的变异测试。
#
# 为什么要有：download_assets_test 的每条断言都必须"咬得住"——把某处修复改回旧行为，
# 套件必须红。存活的变异 = 那条断言只是装饰。
#
# 纪律（上一批踩过的坑）：绝不把输出接 `| head`（SIGPIPE 会杀在还原之前，把变异留在树里）；
# 输出写文件再读；结束用 cmp 断言逐字节还原。
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
TARGET=src/lua/download.lua
ORIG=/tmp/download.orig.$$
OUT=/tmp/mut_assets_out.txt
cp "$TARGET" "$ORIG"
restore() { cp "$ORIG" "$TARGET"; }
trap restore EXIT INT TERM
: > "$OUT"
set +e          # 变异存活时 python 以 1 退出，不能让 set -e 跳过下面的还原核对

python3 - "$TARGET" "$ORIG" "$OUT" <<'PY'
import subprocess, sys, shutil

target, orig, out = sys.argv[1], sys.argv[2], sys.argv[3]
src = open(orig, encoding="utf-8").read()

MUTS = [
    ("M1 解出0成员仍写.done",
     "    local entries = tar_entries(body)\n    if #entries == 0 then",
     "    local entries = tar_entries(body)\n    if false then"),
    ("M2 头以NUL开头即当成归档结束",
     'if hdr:match("^%z+$") then break end',
     'if hdr:match("^%z+") then break end'),
    ("M3 size解析失败即整包break",
     'gsub("%s", ""), 8) or 0\n        if size < 0 then break end',
     'gsub("%s", ""), 8) or -1\n        if size < 0 then break end'),
    ("M4 不过滤目录项/零长项",
     'if name ~= "" and size > 0\n            and (typeflag == "0" or typeflag == "" or typeflag == "\\0") then',
     'if name ~= "" and size >= 0 then'),
    ("M5 忽略调用方给的tar URL",
     "    local url = tar_url\n",
     "    local url = nil\n"),
    ("M6 web回退Referer退回裸站首页",
     '["Referer"] = WeRead.reader_url(book_id),',
     '["Referer"] = "https://weread.qq.com/",'),
    ("M7 errCode静默当成空表",
     '        if code ~= nil and tostring(code) ~= "0" then',
     '        if false then'),
    ("M8 asset_dir不过path_safe",
     'Download.ASSET_DIR, path_safe(book_id), path_safe(chapter_uid))',
     'Download.ASSET_DIR, tostring(book_id), tostring(chapter_uid))'),
    ("M9 命中spool缓存不回填图片",
     "        backfill_assets(book_id, Download.find_chapter(chapters, chapter_idx), cached)\n        return cached",
     "        return cached"),
    ("M10 全本下载跳过已spool章的补图",
     "            backfill_assets(book_id, ch, Download.read_chapter(book_id, ch.chapterIdx))\n",
     ""),
    ("M11 CB_型bookId前缀不按实际id剥",
     "        if name:sub(1, #prefix) == prefix then",
     "        if false then"),
    ("M12 已下载列表丢chapterUid",
     "chapterUid = meta.chapterUid,",
     "chapterUid = nil,"),
    ("M13 backfill_assets整体失效",
     'if not ch or not text or not text:find("\\1IMG:") then return end',
     "if true then return end"),
]

def run_suite():
    p = subprocess.run(
        ["lua5.1", "-e",
         'package.path="src/lua/lib/?.lua;src/lua/?.lua;tests/?.lua;"..package.path;'
         'local f=assert(loadfile("tests/download_assets_test.lua"));os.exit((f() or 0)==0 and 0 or 1)'],
        capture_output=True, text=True, timeout=180)
    return p.returncode, p.stdout + p.stderr

killed = survived = broken = 0
lines = []
for name, old, new in MUTS:
    if src.count(old) != 1:
        lines.append("BROKEN %s（锚点命中 %d 次，应恰好 1 次）" % (name, src.count(old)))
        broken += 1
        continue
    open(target, "w", encoding="utf-8").write(src.replace(old, new, 1))
    rc, output = run_suite()
    if rc != 0:
        lines.append("KILLED   %s" % name)
        killed += 1
    else:
        lines.append("SURVIVED %s  <<< 断言没咬住" % name)
        survived += 1
        lines.append("         输出: " + output.strip().replace("\n", " | ")[:300])
shutil.copyfile(orig, target)
lines.append("")
lines.append("变异 %d 条：KILLED=%d SURVIVED=%d BROKEN=%d" % (len(MUTS), killed, survived, broken))
text = "\n".join(lines) + "\n"
open(out, "w", encoding="utf-8").write(text)
print(text)
sys.exit(0 if survived == 0 and broken == 0 else 1)
PY
status=$?
restore
trap - EXIT INT TERM      # 还原已完成：别让退出时再跑一次 restore（那时 $ORIG 已删）
if cmp -s "$ORIG" "$TARGET"; then echo "RESTORE-OK（$TARGET 与变异前逐字节一致）"; else echo "RESTORE-FAIL"; status=1; fi
rm -f "$ORIG"
exit $status
