#!/bin/bash
# 变异测试：改坏 menu.lua 的新逻辑，看 tests/menu_ui_test.lua 是否报错。
# 输出全部落文件，绝不用 | head（上一批 SIGPIPE 打断过还原，把变异留在树里）。
set -u
cd /home/doro/WereadK4_BasedDK
cp src/lua/menu.lua /tmp/menu.orig
restore() { cp /tmp/menu.orig src/lua/menu.lua; }
trap restore EXIT

py() {
python3 - "$1" "$2" "$3" <<'EOF'
import sys
old, new, path = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path, encoding="utf-8").read()
if old not in s:
    print("PATCH-NOT-FOUND"); sys.exit(3)
open(path, "w", encoding="utf-8").write(s.replace(old, new, 1))
EOF
}

MUT=/tmp/mut_out.txt
LOG=/tmp/mut_run.txt
: > "$MUT"
run_case() {
  local name="$1" old="$2" new="$3"
  restore
  if ! out=$(py "$old" "$new" src/lua/menu.lua); then
    echo "$name: PATCH-FAIL $out" >> "$MUT"
    return
  fi
  timeout 120 lua5.1 tests/menu_ui_test.lua > "$LOG" 2>&1
  local res first
  res=$(grep -c "^FAIL menu_ui" "$LOG")
  first=$(grep "^FAIL menu_ui\|RUN-FAIL\|error" "$LOG" | head -1 | cut -c1-110)
  if [ "${res:-0}" -gt 0 ]; then
    echo "$name: KILLED ($res fails) :: $first" >> "$MUT"
  else
    echo "$name: *** SURVIVED ***" >> "$MUT"
  fi
  restore
}

run_case M1_reject_bad_font 'if not ft then' 'if false and not ft then'
run_case M2_no_immediate_swap 'ft_main = Fonts.load(30)' 'ft_main = ft_main or Fonts.load(30)'
run_case M3_sync_gate_ignored 'if not force and Config.load().progress_sync == false then' 'if false then'
run_case M4_percent_denominator 'Report.position_of(chapters, rec.chapter_idx, rec.page, rec.total_pages)' 'Report.position_of(chapters, rec.chapter_idx, rec.page, rec.page)'
run_case M5_jump_even_if_local 'if side ~= "remote" then' 'if false then'
run_case M6_manual_sync_no_force 'read_book(last, true)' 'read_book(last)'
run_case M7_fullbook_count 'count, from = math.huge, 1' 'count, from = 5, 1'
run_case M8_cancel_misreported 'stats.cancelled and "已取消" or "下载完成"' '"下载完成"'
run_case M9_tail_from_current 'local count, from = 5, pos + 1' 'local count, from = 5, pos'
run_case M10_no_last_chapter_guard 'if from > #chapters then' 'if false then'
run_case M11_failure_prints_zeros 'if not dl then' 'if false then'
# M12/M13 专测严格桩：改名/改错字段名在真机是崩溃或死键，静默 nil 的 mock 会漏
run_case M12_renamed_sync_field 'Sync.remote(book_id)' 'Sync.pull(book_id)'
run_case M13_renamed_report_field 'Report.position_of(chapters' 'Report.position2(chapters'

cmp -s /tmp/menu.orig src/lua/menu.lua && echo "RESTORE-OK  tree identical to backup" >> "$MUT" || echo "RESTORE-MISMATCH" >> "$MUT"
