# LOG — 动作日志（ub-mode）

### 图片加载落地 + 遗留清理（用户口径：清理+持续优化+修复图片加载）

**清理**：/mnt/us/weread/bin（34.8MB，闭源包 kindlehf/kindlepw2 多设备遗留）+
weread.pre-1120-sync（3MB 旧副本）→ 备份 tar 落本机 backups/（17MB）后删除；
/mnt/us/weread 53→15.4MB，/mnt/us 使用率 45%。

**图片链路（全取证驱动，DK-3 图片路径落地）**：
1. 取证：epub 章 xhtml 的 `<img src="../Images/note.png">` = 包内相对路径；
   正文分片不含图；资源在 web `/web/book/chapterInfos` 响应的 `chapter.tar`
   （res.weread.qq.com/wrco/tar_CB_<book>_<idx>，302→CDN）；tar 成员名带
   `CB_<bookId>_` 前缀（CB_3300057890_note.png）与正文裸 basename 不对齐；
   chapterInfos 的 files 数组=xhtml 清单非图片映射。
2. C 层：stb_image（public domain，upstream 副本；SDL3 vendored 副本有
   Uint8/Sint16 类型污染弃用）编入 wrbridge：`wr.image_decode(bytes)`→gray,w,h、
   `wr.image_scale`（**缩放必须在 C**：Lua 拼 60 万 string.char 参数爆栈）、
   `wr.fb_image(x,y,w,h,gray)`（亮度→墨量 255-gray，越界裁剪）。weread-dyn
   3.02→3.08MB。**绑定返回序 = gray,w,h**（先串后数）。
3. Lua：html_text img→`\1IMG:<basename>\1` 标记（无 src 兜底 [图片]）；
   download `fetch_tar_map`（web chapterInfos，每书缓存）+`ensure_chapter_assets`
   （tar 下载 302 手动跟≤3 跳 + 512B ustar 解析 + `CB_%d+_` 前缀剥除落盘
   imgcache/<book>/<uid>/ + .done 幂等）；ensure_chapter 正文含标记时自动取资产
   （失败不拦正文）；delete_book/all 同步清 imgcache。
4. reader 块级排版：layout 行元素=字符串|图片块表（占 total 行槽，槽=页高/lh+1，
   块内原子不跨页——装不下垫空行到页界）；draw 仅 slot=top_pad+1 画一次；
   解码会话缓存；资产查找精确名+`_name$` 后缀兜底。
5. **顺手修正上批静默未生效的补丁**：reader 页脚点阵化实际没落盘（python
   replace 无校验的 no-op，f1c129d 描述不准）——本批以 assert 驱动替换落实。

**设备端到端实证**：游隼 ch3 重下→tar 2341B note.png 解包落盘→PNG 解码
48×48→fb_image 黑/白极性像素级验证（黑→255/白→0）→layout 4 标记→4 块×3 槽
共 217 行。测试：html_text 标记断言 + tar 解析合成字节断言 + menu_ui 桩补
asset_dir，**23 套全绿**。


### 菜单重组+设置分组/边距+运行状态修复+已下载删除+硬件占用对比

**用户口径**：同步进度/检查连接/运行状态归入设置；设置分组+分组线；设置加
上下左右边距；运行状态显示不正常修复；已下载加单独+批量删除；硬件占用 vs
KOReader 对比。

### 动作

1. **主菜单收敛 5 项**：继续阅读/书架/已下载/设置/退出（离线·登录失效追加扫码
   登录）；同步进度/检查连接/运行状态移入设置屏。
2. **设置屏函数化 settings_screen + 分组**：阅读（字号8档/行距/左右边距/上下
   边距/字体）─ sep ─账号（云端进度/检查连接/同步进度）─ sep ─系统（运行状态）；
   分组线=不可选行，导航 step_e 跳过（**教训：Down 步数与行号因此错位**——
   menu_ui 三个用例键数按"可选项序号"重算）；动作项无 opts（ipairs 加守卫）；
   sel_e 声明必须先于 step_e（严格 _G 抓全局泄漏）。
3. **边距 config 化**：reader margin_x(20/30/40)/margin_top(16/24/32)，
   MARGIN_BOTTOM=44 固定（页脚区）；守卫 12-80/8-60。
4. **运行状态屏修复（真机取证）**：app.log 行最长 114 字符 ×16px ≈1800px 远超
   600px 屏——长行画出右边缘即"显示不正常"。修复=所有行 clip（utf8_substr 按
   最坏 CJK 全宽 32 字符）+ meminfo 解析成一条（MemTotal/MemFree MB）。
5. **已下载删除**：delete_chapter/delete_book/delete_all（delete_book 数字 id
   守卫）；browse 重扫结构（删除后回上层重新 list_books）；书目层末行「批量
   删除（清空已下载）」+ 章层末行「删除本书下载」，均走 confirm 确认屏
   （中键确认/Back 取消）+ toast。**设计权衡：撤销"删除本章"动作行**——动作行
   上没有章节上下文，语义不成立；单章删除留待管理模式（单章文件小，书级是
   自然删除单元）。
6. **download_list_test 加删除 8 断言**（单章/重复拒/整书/非数字拒/清空）。

### 硬件占用实测（K4 600×800，19:44 现场数据）

| 项 | 本项目(weread-dyn) | KOReader(v0.6.0-k4-v9.12) |
| --- | --- | --- |
| 进程 RSS 峰值 | **4.5MB（单进程）** | 19.2MB 主进程+2 子进程 2.6MB×2 ≈ **24.4MB** |
| VSZ | ~12MB | 51MB |
| 冷启动到可用 | ~1s（SMOKE 实测秒级） | 45s 时仍在初始化（werad 插件 25s 才 ready） |
| 安装盘占 | 核心 ~10.7MB（二进制6+字体5+lua0.5+lib1.9） | 193MB |
| 待机 CPU | ~0%（input ioctl 阻塞） | ~0%（同为阻塞轮询） |

注：/mnt/us/weread/bin=34.8MB 是 isword 0.3.9 时代遗留（+weread.pre-1120-sync
3MB 旧副本），非本项目运行所需，可回收 ~37.8MB（待用户点头清理）。

### 验证

- `lua5.1 tests/run.lua`：**23 套全绿**；luac 零错；部署 SMOKE PASS EXIT=0；
  auth.json 与 .bak-batch5 一致；KOReader 实测后已清理恢复（kill reader.lua +
  CONT cvm/volumd + send 139，设备已回 home）。


### UI 紧凑化（用户口径：多看风、字体偏大）

**设计令牌**（600×800，全线统一，一处调整全线跟随）：标题 26→26 / 列表主字
30→24 / 小字 16 / 行高 46→38 / 标题区 44→36 / Y0 84→76 / 分隔线 2px 黑→1px
灰（阅读页脚除外）。menu/shelf/downloaded/toc/快捷菜单/状态屏/登录屏全按同一套。

### 动作

1. menu.lua：菜单主字 24/小字 16；行高 38；设置字号选项 4 档→8 档
   （16/18/20/22/24/26/28/30）；字体切换回执重开面 24/16；状态屏行距同步
   （38/26）。
2. shelf.lua：24/16，行高 38（ROWS=10 最近阅读口径不变，只收紧行距）；
   作者列右移 440。
3. downloaded.lua：24/16，行高 38。
4. reader.lua：**默认字号 26→22**（设备 config 用户已自选 22，默认对齐）；
   FONT_MIN 18→16（配合 8 档选项）；页脚 56→44（正文区每屏多 12px），
   页脚改 16px 点阵定宽灰字居中（不占 freetype 槽位、与正文字号无关）。
5. config.lua DEFAULTS.font_size=22；auth.lua 登录屏 24/16。
6. 测试适配：config_test 默认 26→22（两处）；menu_ui_test 字体回执断言
   24/16。reader_layout_test 23/15 行断言在 MARGIN_BOTTOM=44 下仍成立
   （732/31=23、732/46=15，显式传参不经默认值）。

### 验证

- `lua5.1 tests/run.lua`：**23 套全绿**；luac 零错；部署后 menu SMOKE
  PIXEL-CHECK PASS EXIT=0；auth.json 与 .bak-ui2 一致。


### 已下载点击崩溃 + 书名回填（真机取证 reader.lua:105）

**用户报**：已下载列表显示书号非书名；点击打不开；退出后报错。

### 取证

- start.sh v3 的应用输出重定向在 `/mnt/us/weread/data/start.log`（非 KUAL.log——
  KUAL.log 是 11-20 的陈旧文件，此前的排障误把 KUAL.log 当现场）。真机日志：
  `lua error: reader.lua:105: attempt to index local 'text' (a nil value)`，rc=1，
  08:40/18:14 两次会话同一错误。点击→应用崩溃→无响应；"退出后报错"=崩溃下游
  （framework 恢复期弹窗），非独立缺陷。

### 动作

1. **解包 bug 修复（downloaded.lua 层2）**：`ch_entries[sel_ch]` 是
   `{label, chapter}` 包装表，旧代码直取 `c.text/c.title/c.chapterIdx`——全 nil →
   `Reader.open(nil,...)` → `Reader.layout` 对 nil `gsub` 崩掉整个应用。修复=取
   `.chapter`；抽出纯函数 `DL._chapter_entries`（回归钉）。教训：列表条目包装
   "显示字段+数据字段"时，解包侧必须显式走数据字段——这种 bug 主机测不进 UI
   循环就漏，靠真机崩溃才暴露。
2. **书名回填（downloaded.lua `DL._backfill`）**：旧 spool（manifest 体系之前落的）
   只有书号。browse 进入时若有书缺 manifest 且已登录：shelf 查书名（catalog 响应
   已探明无书名字段，只有 bookId/chapters/synckey）+ 每本 catalog 拉目录 →
   save_manifest。一次性（落盘后不再触发）；未登录/查不到名/失败 → 静默保留
   书号显示，离线浏览不因此不可用。过程提示屏。部署后已在设备执行一轮：
   5/5 全部拿到真实书名+完整目录（盲视33章/游隼8/我为什么写作16/安妮·卡森15/
   写作与生活55）。
3. **Log 埋点**：browse 进入书数、离线打开（book/ch）、回填逐本——真机留痕。
4. `tests/downloaded_test.lua` 新建（8 断言）：_chapter_entries 包装形状 +
   _backfill 筛选/查名/跳过/未登录四态。**套件隔离教训**：run.lua 单进程顺序跑，
   桩替换必须先于 require（模块加载期捕获引用）、api 原地改写按函数粒度还原、
   pcall 兜底保证还原必达——首次三桩泄漏连坐 sync/reader 两套件。

### 验证

- `lua5.1 tests/run.lua`：**23 套全绿**；luac 零错；部署后 SMOKE PASS EXIT=0。
- 设备实证：backfill 5/5 书名+目录落盘；真实 spool 正文（36KB）过
  Reader.layout 769 行无错（原崩溃点）。


### 账号状态 + UI 打磨（用户口径：在线/离线/扫码登录）

**目标**：主菜单显示账号状态（在线/离线/未登录），提供扫码登录与显式检测入口；
顺手 UI 打磨（右上角时钟、状态屏加账号行）。

### 动作

1. `src/lua/auth.lua`：`Auth.last_renew_result`（renew 各 return 点记录最近续期结论，
   发起真探测时清旧值防"在线"残留）+ `Auth.status()`（不触网映射：未登录/已登录/
   在线 replaced|stale/离线·登录失效 expired/离线·无网络 network）。
2. `src/lua/menu.lua`：
   - 页脚右侧常驻账号状态（Auth.status），标题行右侧 MM-DD HH:MM 时钟（小字右对齐）；
   - 「登录」→「扫码登录」（两态菜单）；登录失效态（离线·登录失效）菜单**追加**
     「扫码登录」项——只在用户显式选择时才出二维码（绝不自动扫码，风控约束）；
   - 登录态菜单加「检查连接」：Auth.renew(true) 显式探测 + 60s menu 层防抖 +
     结论如实回报（在线会话已续期/凭据稍受限/登录失效可扫码/无网络/冷却中/
     缺 refreshToken）；修复 res 作用域 + draw() 三返回值接收（状态随检测刷新）；
   - 运行状态屏加「账号: <状态>」行。
3. 测试：renew_test 加 Auth.status 六态断言；menu_ui_test 适配 8 项菜单键位
   （检查连接=pos5、设置=pos6、运行状态=pos7）+ 新增 1a2（离线失效态追加扫码登录、
   页脚如实显示、不再显示已登录）与 1b（检查连接：过程提示+冷却中如实回报）+ 状态/
   时钟页脚断言；auth 桩补 status（可变桩 auth_status_ret）。

### 验证

- `lua5.1 tests/run.lua`：**22 套全绿**；全仓 luac 零错；make host-selftest OK。
- **设备部署 pending**：设备休眠断 WiFi 掉线（ssh no route，两次重试间隔 90s）。
  设备上线后：`tools/deploy-weread.sh`（auth.json 备份纪律照旧）→ menu SMOKE →
  真机验收三态页脚/检查连接/扫码登录入口。


### fpcheck 并入【Kual】菜单（用户口径补落实，KUAL 仓 a8b5127）

- 机制取证：KUAL 内置【Kual】菜单由 parse.awk `json_self_menu()` 合成（serial 0，
  show_KUAL_buttons=2/3/99→Sort/Save log/Quit），与扩展树同入 MENUS 数组，经
  collate() 做**同名同级子菜单合并**（collate 默认开）→ 扩展根项命名 "KUAL" 即并入。
- 设备实证：基线（现菜单重跑 fork parse.awk）md5 与 /var/tmp/KUAL.cache 完全一致；
  改 fpcheck/menu.json 根项为 "KUAL" 子菜单（条目 priority=4）→ 根级按钮 6→5
  （fpcheck 独立按钮消失），「Write fingerprint report」落 `1:ff00ff00ff030b`
  =【Kual】子菜单内；根按钮显示 **"KUAL+"**（上游 collate 合并标记，非异常）。
- 设备 menu.json 已部署、KUAL.cache 已重建（下次启动直接生效）；本机同步：
  /home/doro/KUAL deploy-k4/fpcheck+README+LOG.md（a8b5127 已提交），
  本仓 kual/README.md 旧表述更正。

### 已下载书目 + 运行状态（测试 log 调试面，本批）

**目标**：主菜单新增「已下载」（离线浏览已下载书目→章→阅读）与「运行状态」
（内存/Lua堆/spool占用/错误计数/app.log 尾部）；log.lua 运行日志落地调试面。

### 动作

1. `src/lua/lib/log.lua` 新建：PATH=/mnt/us/weread/data/app.log（可注入主机 tmp），
   级别 D/I/E（默认 I，debug 不落盘），200KB 超限按行边界截半轮转（保新丢旧），
   `Log.errors` 进程内计数 + `Log.error_count()` 全日志 [E] 累计 + `Log.tail(n)`。
   修复：tail 对文件尾 \n 不得多出空尾行（真 bug，测试抓出）。
2. `src/lua/download.lua`：manifest 体系 `save_manifest/load_manifest`
   （books/<id>/manifest.json：title/last_download/chapters[chapterIdx,Uid,title,wordCount]）；
   `list_books()`（纯数字目录扫描、last_download 降序、bytes/chapters_down 统计，
   无 manifest 回退显示 id）；`list_downloaded_chapters()`（manifest∩spool，升序，
   标题来自 manifest）；`Download.book` on_progress 回 false → 取消传播修复。
3. `src/lua/lib/downloaded.lua` 新建：`DL.browse()` 书列表→章列表→Reader 单章阅读，
   list_loop 通用列表循环（Up/Down 回卷、Left/Right 翻页、Back 返回）；纯离线不触网。
4. `src/lua/menu.lua`：两态菜单加「已下载」「运行状态」；`status_screen`（/proc/meminfo
   前3行、collectgarbage 堆、spool X本/Y章/大小、错误计数 本次/累计、app.log 尾8行）；
   `read_book(book_id, force_sync, title_hint)` 落 manifest + Log 埋点；
   reader/download 关键路径 Log.info/error（下载字节数耗时、reader 分页数）。
5. 测试：`tests/log_test.lua`（写入/级别过滤/轮转截半/计数/tail/不可写回退 6 用例）；
   `tests/download_list_test.lua`（manifest 回读/纯数字目录过滤/∩语义/降序/无manifest
   回退 6 用例，os.time 桩错开避免同秒排序不稳）；menu_ui_test 适配新菜单布局
   （7项键位偏移是根因：旧脚本 Press 命中「已下载」触发严格桩报错）+ 新增 7b/7c
   两入口接线断言；download 桩补 save_manifest/list_books、新增 downloaded/log 桩。

### 验证

- `lua5.1 tests/run.lua`：**22 套全绿**（新增 2 套）；全仓 luac -p 零错；C 层未变免重编。
- 设备部署（auth.json 先备份 .bak-dlmenu，部署后 md5 与备份一致=登录态无损）：
  menu SMOKE PIXEL-CHECK PASS EXIT=0；数据面真机冒烟：list_books 识别 5 本真实 spool
  （字节数正确）、list_downloaded_chapters 章数/标题回退正确、Log tail/error_count 正常。
- 已知形态：旧 spool（manifest 之前落的）total=0/title=id——首次打开该书后
  read_book 落 manifest 自动补齐；不是缺陷。


### KUAL 菜单改造（用户三项口径，cdbf052）

- **微信读书=主菜单单按钮直接启动**：menu.json 单条 depth-1 action 项（KUAL 源码
  levelMap 语义：depth-1 items=主菜单按钮），子菜单（启动/报告/恢复三项）去除；
  点击「微信读书」→ start.sh v3 → 应用。真机 menu.json 已部署（v2 备份 .v2-backup）。
- **fpcheck「Write fingerprint report」**：独立 KUAL 根级条目保持原位（gawk 调试
  工具遗留，非本项目功能）；diagnose/recover 脚本保留设备侧走 ssh。
- **退出报错弹窗取证（无崩溃）**：start.log rc=0、volumd/cvm SIGCONted 干净、无
  framework 重启；弹窗=cvm 恢复后自身的 Amazon 注册/同步失败（UnknownHostException
  firs-g7g.amazon.com——Amazon 端点在用户网络不可达，环境性；stock 设备同样出现），
  与应用退出无因果。非本项目缺陷，无法在不破坏系统的前提下消除。

## 2026-11-20 · 二轮独立审查：修复面全量复核 + 两个新修复 + 变异复核

**目标**：以 211540 交接为基线（FRESH），对四项需求批次的 11 提交/24 文件（+2007/-97）做 ub-mode + code-review 全量审查。

### 新增修复（本轮提交）

| 级别 | 位置 | 发现 | 处置 |
|---|---|---|---|
| 🟡 | download.book on_progress | 回调返回 false 不可达（只 pcall 不接返回值）→ 151 章全本下载按 Back 无法取消 | ✅ Book 识别 false→ch._err="cancelled"+中断返回（已完成章保留）；download_batch 识别→"已取消（已完成部分保留）" |
| 🟡 | auth.lua 三处硬编码 wqy 路径 | clear_screen/draw_login_screen/hint 绕过 fonts.lua 唯一决策点（换字体后这三屏仍是微米黑） | ✅ 改 Fonts.load（回退语义保留） |
| 🟢 | menu.lua 顶部过期字体注释 | 更新指向 fonts.lua | — |

### 审查正面结论（他们的工作）

- fonts.lua：唯一决策点 + Fonts.probe 探测缝可单测 + open/load 分离（回退不掩盖坏文件）——设计优秀
- sync.lua：纯函数 + 阈值口径与插件一致 + 不用弹窗选择题（五向键每次提问都是成本）
- download_batch：取消位 + e-ink 重绘 3s 限流（口径同插件 download_dialog）
- shelf.go_page 越界卷页数学验证正确（取模回卷+min 兜住半页）

### 变异复核

mut-menu.sh 13 变异 **13/13 KILLED**；RESTORE-OK 树还原逐字节一致。本轮两个修复后全量回归保持绿（19 套 + 双变体构建零错 + host-selftest）。

### 提交

- c4a0663 二轮审查修复（取消传播 + auth 字体路由）
- 本条 LOG

## 2026-11-20 · 书架分页 + 可换字体 + 全本下载 + 进度同步（四项需求，主机 19 套 + 真机三项取证）


**目标**：设备重新上线，复跑全部设备 smoke——**抓到并修复上批格式探测的一个回归**。

### 回归与修复

**格式探测顺序回归（本轮 dk3_smoke 6 failures 的根因）**：上批把 `e_0 == "{}"` 短路成
EMPTY-SHARD，但取证实证 **txt 书的 e_0 恒返回 "{}"**（e_* 是 epub 分片端点）——短路使
txt 路径连同会话续期重试整体不可达。修复为顺序判定：①JSON+bookId=txt → ②可解码
xhtml 分片(>32B)=epub → ③"{}"/空=信息不足按 txt 尝试（t_0 空触发续期重试）。

### dk3_smoke 口径校准（服务端真相）

封面/版权页在 txt 书上**服务端真相就是无文本**（t_0 空）或以图片分片形态出现（e_0 有
内容剥标签后=[图片] 8 字节占位）。断言口径从「5/5 全有正文」校准为：多数章有真实正文
（≥batch/2）+ 图片占位正确落盘；幂等口径允许图片页重试 ≤2。修正后 **dk3_smoke 0 failures**
（4/5 spool：3 章真实正文 2649-3066B + 1 占位）。

### 五 smoke 复跑结果（全绿）

- dk3_smoke 0 failures（续期链路活：renewal=replaced → 正文恢复）
- download_smoke EXIT=0（封面页 [图片] 占位正确）
- renew_smoke 0 failures（3066B 真实正文）
- reader_render_smoke ALL PASS（3300235630/ch3 55 行回环 + body-max=255）
- read_report_smoke 0 failures（jar 6 项 header 未见变化）
- net_smoke done
- 菜单 SMOKE PASS

### v3 启动器与 push（用户批准）

- **start.sh v3 落地**（3737d62，已部署+真机生命周期验证）：cvm/volumd SIGSTOP 冻结 →
  应用 → CONT → `echo 'send 139' >/proc/keypad`×2 注入 Menu 键让解冻的 cvm 自己重绘
  home——KOReader 默认退出同款，无树 logo、无 framework 重启。弃 v2 framework
  stop/start（init 固有 logo_screen 屏显为用户不可接受的视觉成本）。
- **push 完成**（用户批准"提交"）：b00672b..3737d62 推送 origin/main，工作区与远端一致。
  push 前泄露扫描：outgoing diff 中 2 处 IP 命中均为**删除行**（泄露收敛本体），无新增泄露。
- 泄露历史 blob 仍在公开仓历史中——filter-repo+force push 仍待用户单独决策。

### 待办不变

设备键位手感验收（跨六批）；push 已完成；泄露历史改写仍待用户单独决策。

## 2026-11-20 · 二轮独立审查：修复面全量复核 + 两个新修复 + 变异复核

**目标**：以 211540 交接为基线（FRESH），对四项需求批次的 11 提交/24 文件（+2007/-97）做 ub-mode + code-review 全量审查。

### 新增修复（本轮提交）

| 级别 | 位置 | 发现 | 处置 |
|---|---|---|---|
| 🟡 | download.book on_progress | 回调返回 false 不可达（只 pcall 不接返回值）→ 151 章全本下载按 Back 无法取消 | ✅ Book 识别 false→ch._err="cancelled"+中断返回（已完成章保留）；download_batch 识别→"已取消（已完成部分保留）" |
| 🟡 | auth.lua 三处硬编码 wqy 路径 | clear_screen/draw_login_screen/hint 绕过 fonts.lua 唯一决策点（换字体后这三屏仍是微米黑） | ✅ 改 Fonts.load（回退语义保留） |
| 🟢 | menu.lua 顶部过期字体注释 | 更新指向 fonts.lua | — |

### 审查正面结论（他们的工作）

- fonts.lua：唯一决策点 + Fonts.probe 探测缝可单测 + open/load 分离（回退不掩盖坏文件）——设计优秀
- sync.lua：纯函数 + 阈值口径与插件一致 + 不用弹窗选择题（五向键每次提问都是成本）
- download_batch：取消位 + e-ink 重绘 3s 限流（口径同插件 download_dialog）
- shelf.go_page 越界卷页数学验证正确（取模回卷+min 兜住半页）

### 变异复核

mut-menu.sh 13 变异 **13/13 KILLED**；RESTORE-OK 树还原逐字节一致。本轮两个修复后全量回归保持绿（19 套 + 双变体构建零错 + host-selftest）。

### 提交

- c4a0663 二轮审查修复（取消传播 + auth 字体路由）
- 本条 LOG

## 2026-11-20 · 书架分页 + 可换字体 + 全本下载 + 进度同步（四项需求，主机 19 套 + 真机三项取证）

## 2026-11-20 · 书架分页 + 可换字体 + 全本下载 + 进度同步（四项需求，主机 19 套 + 真机三项取证）

**目标**：用户「按键复验均通过，提交推送，请阐述书架原理，是否必须先下载全数据？若是则加分页，
首批只显示最近10本；增加可换字体选项；下载增加全本下载选项（且默认）；增加进度同步，与微信读书端
保持一致的选项，请学习weread_k4插件」。本批次先取证回答书架问题，再按条件实施四项。

### 书架原理（取证结论，不是推测）

- `/shelf/sync` **没有分页参数**：`api.lua` 的 gateway 请求体只有 `api_name/skill_version`
  （无 params 字段），而一次响应就带回全部条目——请求构造与响应体量两头对上。
  真机量级（一次性探针 `/tmp/shelf_probe.lua`，设备 /tmp 运行，不入库）：
  `get_shelf_ms=13903`、`books=10187 / archive=22 / albums=37 / mp=0`、
  重编码 JSON `4 882 297 B`。
- 因此**元数据必须一次拉全**（服务端不提供分页窗口），但**正文不是**：正文按章走
  `/web/book/chapter/t_*`，只在阅读到该章时下载（`download.lua` spool），书架从不预取正文。
- 结论落到实现：分页是**客户端渲染分页**（不是网络分页）。`shelf.lua` 只保留一个状态
  `sel`（全集绝对下标），页号/行区间全部由它导出——没有第二个状态可以与之错位。
  `ROWS=10`，首页 = 服务端 books 序前 10 本（≈最近阅读，符合用户口径）；Up/Down 在全集内
  移动并跨页回卷，Left/Right 整页翻，页间也回卷。10187 本 = 1019 页。

### 四项实现

1. **分页**（`src/lua/shelf.lua`）：`draw_page(books, sel, …)` 单页渲染 + `go_page(delta)`
   页回卷；页脚 `第 p/P 页 · 共 N 本`，单页时不提示翻页。
2. **可换字体**（新 `src/lua/lib/fonts.lua`）：字体路径原先硬编码在 menu/shelf/reader/auth
   四个文件里，换一次字体要改四处；现在只有 fonts.lua 知道候选与回退（`CANDIDATES` 6 项、
   `probe` 是可替换的缝、`open` 不带回退供设置屏验真伪、`load` 带回退保证读得了书）。
   设置屏新增「字体」项：切换时先在设备上真开一次 face，**打不开就不写 config**，
   打开成功则立即重开菜单主/小字面（这一屏就是预览）。
3. **下载全本**（`menu.lua` 快捷菜单 + `download.lua`）：快捷菜单加「下载全本」并排在
   「下载后面 5 章」之前；`count = math.huge, from = 1`。下载中用
   `wr.input_poll(0, true)` 非阻塞轮询给取消时机（单进程无异步，这是批量下载里唯一的按键
   窗口），Back 即停，已落盘的章保留——`is_spooled` 跳过使重跑等于续传（幂等）。
   汇总改由 `Download.book` 的第三个返回值 `stats{total,done,ok,fail,cancelled}` 给出：
   原先调用方自己数 `_err`，数的是它那份目录，而 `_err` 写在返回的那份上——**数字失真**。
4. **进度同步**（新 `src/lua/sync.lua` + `menu.lua` 打开书本时）：拉云端
   `/book/getprogress`，按插件口径比较（`SAME_THRESHOLD_PERCENT=2`），云端领先或本地没记过
   才跳过去，并给可见回执；设置项「云端进度」=关 时整段跳过、一个请求都不发。
   「同步进度」菜单项原先是死项（只 print「已选择」），现在对最近一本强制拉一次并回报判异结果。
   上报方向不需要手动入口：离开每章时 `Report.send` 已经发过。
   `Progress.set` 补 `total_pages`——没有分母，本地页码与服务端 percent 根本不可比。

### 验证

- 主机：`lua5.1 tests/run.lua` → **LUA-TESTS-OK (19 suite(s))**（`tests/run.lua` 收录
  15→19 套：新增 fonts_test / download_batch_test / sync_test / menu_ui_test）。本批次新增/重写
  `menu_ui_test`(12 例) `shelf_ui_test`(8 例) `fonts_test`(8 例) `download_batch_test`(7 例)
  `sync_test`(10 例)，`reader_layout_test` 补 `{fraction=}` 跳转例。
- `menu_ui_test` 的 harness 是**严格**的：`wr` 与各模块桩都过 `strict()`，读到桩里没有的名字
  直接报错（静默 nil 会把"桩没跟上 menu.lua"伪装成"菜单坏了"）；`_G` 装 `__index` 拦未定义
  全局。两处护栏各自抓到过真缺陷：本批次写第一版时 `local DEFAULT_FONT` 被并进注释行 →
  立刻报 `undefined global read: DEFAULT_FONT`。
- 变异测试 `tools/mut-menu.sh`：**13/13 KILLED**，RESTORE-OK。含 M12 `Sync.remote`→`Sync.pull`
  与 M13 `Report.position_of`→`position2` 两例专测严格桩（真机形态分别是崩溃与死键）。
- 真机（K4 在线窗口内完成，之后设备掉线）：
  - `weread-dyn lua/menu.lua --smoke` → EXIT=0，`menu done, sel=1 (smoke) ft=on`，dmesg 无异常。
  - `lua/shelf_smoke.lua --smoke` → `SHELF-PIXEL-PASS`、EXIT=0，**real 15.62s**
    （含 13.9s 的 10187 本全量元数据拉取），新 `draw_page` 在全量数据上渲染正常。
  - `lua/fonts_smoke.lua`（新增）→ 6 个候选 exists=yes 且 freetype open=ok，
    `listable=6`，`FONTS-SMOKE-PASS`。其中**同时常驻 5 个 face** 这一项是对
    `render.h WR_FT_MAX_FONTS 4→8` 扩容的直接证据：`wr_ft_load()` 无去重，每次调用占一个槽，
    槽满即 `-ENOMEM`，旧构建在第 5 个必失败。
- C 层重建：`make weread` + `make weread-dyn`（-Wall -Wextra 无新警告）；设备上两个名字
  都指向 3 018 684 B 的 dyn 构建。

### 顺带发现并修掉的一处泄露（提交前扫描）

提交前按纪律 grep 内网网段，命中**两处已在公开仓库里的字面 IP**：
`tools/deploy-kual.sh:5` 把它写成 `K4_HOST` 的默认值（该脚本连 k4-env.local.sh 都不 source），
以及 LOG 里一行历史叙述。**tip 已修**：deploy-kual.sh 改成与 deploy-weread.sh 同配方
（source local env + `:?` 强制），LOG 那行改成 `<K4_HOST-host>`。
注意：旧条目里那句"`192.168.` 段全仓零命中"当时就不成立（正是这条默认值），
且已推送的历史里值仍在——历史清理属用户已明确"暂时不处理"的事项，本轮只做 tip 收敛。

### 坑与教训

- **变异脚本绝不接 `| head`**：上一批 `bash /tmp/mut.sh | head -1` 的 SIGPIPE 杀在
  `cp` 还原之前，把变异 M2 留在了 shelf.lua 树里（症状：单跑绿、进 runner 11 例红 +
  `bad argument #1 to 'concat'`）。本批次的 `tools/mut-menu.sh` 输出全部落文件，
  并在末尾 `cmp -s` 断言树与备份逐字节一致（RESTORE-OK）。
- 设备在字体/书架取证后掉线（`No route to host`，三轮重试不通）——真机剩余项见下。
- `shelf_smoke.lua` 的 `shown=` 断言是在掉线前部署的，**未在真机跑过**（逻辑与
  shelf.lua SMOKE 的返回串同源，主机 shelf_ui 覆盖 draw_page 返回值）：待设备回来复跑。

### 下一步

1. 设备上线 → `shelf_smoke`（行数断言）+ `dk3_smoke` / `download_smoke` / `reader_render_smoke`
   / `read_report_smoke` / `net_smoke` 复跑；设置屏「字体」与快捷菜单「下载全本」需用户按键手感复验。
2. 死代码已清：`Sync.differs` 无调用方，删除（主机测里那个 `differs` 桩字段一并去掉）。→ 结局: done
3. 待用户决定：设备侧 9 个 `auth.json.bak-*`、GitHub 旧 SHA 清理、LICENSE。→ 结局: blocked 等用户口径
4. 本批定稿动作：交接文档（本地 only）校验 100/100 READY；`AGENTS.md` 交接指针提交为 `a6df9c7`，
   本地 `b00672b..a6df9c7` 共 6 个未推提交，等用户点头。→ 结局: blocked 等 push 决策
5. 更正一处已提交的说法：`40b5bcd` 的提交信息写 "runner 16→19 套"，实际是 **15→19**
   （`git show b00672b:tests/run.lua | grep -c '_test"'` = 15）。LOG 与交接文档已用正确数；
   提交信息本身不改写（amend 需用户点头，且它会改变未推提交的 hash）。→ 结局: done

## 2026-11-20 · 状态核实+设备复验：工作区的"未完成批次"三处缺陷，补两条 UI 回环护栏

**目标**：用户说「核实目前项目状态，K4 目前上线，可测试」——先确认仓库/设备真实状态，
再动设备。全程未扫码（wr_rt 续期路径）。

### 核实结论（证据）

- HEAD `dd439d6`，origin/main `2d60216`，**10 个提交未推**；handoff kit（08:11:42）FRESH，
  但它写「工作区干净」——实际有 6 个未提交文件（08:57–08:58 落笔，即导出之后的进行中批次）。
- **设备并不在 kit 宣称的版本上**：`md5sum` 对四个 git 版本逐个核，设备 menu.lua/download.lua/
  reader.lua 全等于 `fc157df`，且 `/mnt/us/weread/lua/lib/config.lua` **不存在**（该文件是
  `91b19e1` 才加的）→ 结论：`91b19e1` 从未部署到设备。任务板 #1 记的"部署 91b19e1 全量+
  用户 11:3x 复验"与设备证据冲突；若 11:3x 的视觉复验确有其事，那它验的是旧版，
  快捷菜单/设置/行距当时并未生效。
- 未提交批次三处缺陷（都是"看代码看不出来、跑一次就现形"的那类）：
  1. 🔴 **shelf.lua 开机即崩**：`PAGE` 被改名成 `MAX_ITEMS`，`draw_page` 函数体仍在用 `PAGE`
     （6 处）；且 `draw_page` 是 5 参数被 4 参数调用（sel_abs 落到 page 位、ft_main 落到
     sel_abs 位）；按键循环还在按全量 `books` 翻页，而首屏只画裁剪后的 10 本——下标域不一致。
     `page` 变量也从 `local` 变成了隐式全局。设备旧版能跑、新版没跑过。
  2. 🟡 **快捷菜单"下载后面 5 章"必然报"成功 5 失败 0"**：它数的是本函数自己那份
     `chapters`（`_err` 写在 `Download.book` 内部重新 fetch 的那份目录上），
     `Download.book` 的返回值被丢弃、`dl_err` 声明未用；目录取失败也显示成功。
  3. 🟡 设置屏退出条件被删掉 `Menu`（值选择屏仍认 Menu）→ 同一功能两层屏键位不一致；
     设置分支尾部还遗留重复的 `sel = 1 / draw()`（多刷一次墨水屏）。
- `line_factor` 三档 1.3/1.54/1.8 经 `Config.set → Config.load` 浮点恒等（`o.v == curv`
  的"当前档"标记依赖它）；`LINE_H_PER_PT` 在行距改造后成为死代码，删。

### 动作

1. **补齐未完成批次**（只做减法+接线，不改设计）：`draw_page(books, sel_abs, ft_main,
   ft_small, header)` 改为单页渲染（无 page 参数、无 `PAGE`），循环只在裁剪集内导航、
   Press 取 `shown[sel_abs]`；截断时标题栏自报「书架 · 最近 10 本」，页脚删掉"左右翻页"提示。
   下载分支改数 `Download.book` 的返回值、失败显示 `dl_err`、`pos >= #chapters` 时直接说
   "后面没有章节"（否则 `from` 被钳回最后一章、重复下载它）。
2. **tests/shelf_ui_test.lua**：`wr.*` mock + 10185 本假书架 + 按键脚本驱动整条 UI 回环；
   给 `_G` 装 `__index` 拦截——**读未定义全局当场 error**，`PAGE` 那类"改名漏改引用"在主机
   就死（设备 SMOKE 只渲染一帧、不进循环，正是它的盲区）。
3. **tests/reader_layout_test.lua**：字号/行距进到分页的行为证明（标准档必须复现改造前的
   固定行高 40px→每页 18 行/全书 5 页，紧凑 21 行、宽松 15 行，末页再翻给出 next_chapter）。
   锚点是历史事实，不是把公式重述一遍。

### 验证

- `lua5.1 tests/run.lua` → LUA-TESTS-OK (**15 suite(s)**)；`make weread`/`weread-dyn` 0 error；
  `make host-selftest` → HOST-OK + INPUT-OK。
- **变异证明两条新测试不是摆设**（`cp` 备份+`cmp` 校验还原，绝不用 `git checkout --`——
  这些文件未提交，checkout 会连修复一起抹掉）：
  `for idx = 1, #books`→`PAGE` ⇒ 11 FAIL，首条 `undefined global read: PAGE`；
  去掉 10 本上限 ⇒ 3 FAIL（`实得 10185 行`、回卷选中 `B10185`）；
  `line_h` 忽略设置 ⇒ 2 FAIL（三档全 18 行/5 页）。还原后全绿。
- **真机（在线）**：先 `cp auth.json auth.json.bak-verify`；旧 spool 不删——`mv books
  books.pre-spool-contract`（3 章带标题头的缓存原地可查）+ 新建空 `books/`；
  5 个文件定向 scp（md5 双端一致）。
  `renew_smoke` → 0 failure（会话仍可用、force→replaced、冷却挡住第二次、取到 3066B 真正文）；
  `dk3_smoke` → 0 failure（新 spool 5 章，「封面」8 字节 ⇒ 标题头确已消失，缓存重跑 0 次网络）；
  `shelf_smoke` → SHELF-PIXEL-PASS（exit 0，旧写法在此当场崩）；`menu --smoke` → PIXEL-CHECK PASS；
  `reader_render_smoke` → rows=55 roundtrip OK。
- **并发写提醒**：任务板 #9/#10（Grok：快捷菜单四选一、书架/目录分页）与 #11/#8（Codex：
  翻页长按连翻、Back/Menu 拆分）标着 in_progress，与本次动的 menu.lua/shelf.lua/reader.lua
  同一批文件。我把"裁剪 10 本"补成了自洽实现，而 #10 的计划是"加分页"——两者相互冲突，
  必须串行，否则谁的版本落地都是偶然。

## 2026-11-20 · 代码核实批次：快捷菜单 UI + 设置落地 + spool 契约修正（设备离线，全主机验证）

**目标**：用户离开前核实代码并继续项目（设备无关部分）。

### 核实结论

- download.lua 重写后全貌 ✓（fetch_psvts 三值返回/pclts/token 链已由后续会话修好——此前误判撤销）。
- **发现两处行为问题**：
  1. Menu 键在阅读态落入 else=exit 分支（quickmenu action 无人处理）→ 按 Menu=静默退出书；
  2. epub 书阅读页标题双显（spool 头 title + xhtml 自带 h2 各一次）。
- 快捷菜单设计差异说明：DK-3 会话曾采用"三键共用目录屏+末项退出"合并设计；用户实证期望
  独立快捷菜单（keymap 文档 §二语义），本批按用户语义实施（拆分保留）。

### 动作

1. **quick_menu 三选一屏**（menu.lua，Menu/ScreenKB+Down 触发）：继续阅读/章节目录/退出阅读，
   Back=继续阅读；read_book 补 quickmenu 分支（resume=回原页/toc=进目录/exit=退出，进度已在
   上方统一落盘）。
2. **设置落地**：lib/config.lua（DEFAULTS 集中/损坏回退/原子写+sync）+ reader 字号从 config
   读（FONT_MIN/MAX=18/40 钳制，行高等比）+ menu「设置」项字号选择（20/22/26/30）。
   tests/config_test.lua 7 断言（缺省/回读/保留用户键/损坏回退/无 .tmp 残留）。
3. **spool 契约变更**：save_chapter 只存正文原样（不拼标题头）——epub 双显修复；
   download_pure_test 断言同步；**设备 spool 需再清一次**（旧缓存含标题头）。
4. 部署状态核对教训：本机命令链的 process substitution 在 BusyBox ssh 上语法报错
   会吞掉后续命令——设备文件状态核对要用独立简单命令。

### 验证

- `lua5.1 tests/run.lua` → LUA-TESTS-OK (13 suite(s))（新增 config_test/html_text_test）
- `make weread && make weread-dyn` → 0 error；host-selftest → HOST-OK + INPUT-OK
- **设备第四次掉线**（本轮 spool 清理命令未送达）→ 恢复后需：全量部署 + `rm -rf books/*` +
  用户复验（白底黑字/epub 正文/快捷菜单/设置字号/退出无弹窗）

## 2026-11-20 · 二轮验收取证（退出仍重启=exitmenu 假阳性根因 + 乱码=部署缺失+跨分片解码）

**用户二轮报告**：①大范围乱码；②退出仍是重启。

### 取证结论（两个真根因，均确凿）

1. **退出仍重启 = exitmenu:false 假阳性场景**：start.log 证实用户 07:59/08:01 两次测试
   跑的已是 framework-stop 模式（rc=0/143，无崩溃日志）——弹窗重启的机制是 isword
   menu.json 启动项 **exitmenu:false**：KUAL 点击后不自杀，framework stop 强杀活着的
   KUAL booklet → 非自愿死亡被 framework 记为崩溃 → 弹"发生错误"+framework 重启。
   k4weread.sh 先例依赖的"KUAL 自杀→再停 framework"被 exitmenu:false 破坏。
   → 修复：menu.json 部署源（kual/menu.json）启动项 **exitmenu:true**，设备已部署
   （原文件备份 menu.json.orig-isword；kual/menu.json.README 记录机制）。
2. **大范围乱码 = 两个叠加**：
   a. **部署缺失**：上一轮 deploy-weread.sh 遇设备掉线未完成（html_text.lua 不在设备、
      download.lua 无 decode_shards）——用户测到的是旧代码+旧 spool 缓存。
   b. **跨分片解码错误（真 bug）**：t_0/t_1、e_0/e_1/e_3 只是同一 base64 流的切段，
      必须拼接后**单次解码**（plugin decode_content_shards 语义）；旧代码逐片独立解码
      从第二片起全错位。已改 Shard.decode_shards（txt/epub 两路），fetch_chapter_text
      整体重写（grab_txt 合并 t_1 进解码流；epub 收 e_1/e_3 原始分片入同一解码）。
3. **部署补全**：全量 lua（含 html_text）+ menu.json + **清空旧解码 spool**（books/*，
   旧缓存不可信）。html_text 剥 UTF-8 BOM（freetype 渲染为怪字形）。

### 真机复验（全绿）

- menu SMOKE PASS；download_smoke（txt 书重下）PASS——封面页正确显示"[图片]"占位
- epub_verify：3300070895 ch4 = **8035 字节**、非空白 8005、无 FFFD——标题重复=
  xhtml 自带 h2 章题（spool 头+正文标题各一次，非乱码）
- FFFD 全 spool 零命中

### 交用户第三轮复验

KUAL>微信读书>启动微信读书（**菜单会立即消失=exitmenu:true 正常行为**）→ 白底黑字
菜单 → 开书读正文 → 退出（framework 重建回主屏，不应弹窗）。若仍有异常：
diagnose.sh 报告 + start.log/KUAL.log。

## 2026-11-20 · 修复部署与设备侧验收（7 项修复全绿，交用户视觉复验）

**目标**：部署上一批修复（极性/键位/epub/framework 模式）并设备侧逐项验收。

### 结果（全绿）

1. 凭据备份（auth.json.bak-deploy2）→ 全量部署 → 菜单 SMOKE PASS（极性后自检改判亮）。
2. **epub 路径真机 PASS**（epub_verify.lua）：3300070895《我为什么写作》ch4 = 8018 字节真实正文
   （"一个书评家的自白 在一个寒冷…"）——乱码修复确认；剥离器保留全角空格缩进。
3. **epub 章节渲染回环 PASS**（reader_render_smoke 3300070895/ch4）：326 行布局回环 OK +
   像素 body-max=255（墨量极性黑笔画）。
4. renew_smoke：0 failure(s)（续期后 3211 字节真实正文）——凭据门禁/续期不受修复影响。
5. **framework stop/start 生命周期复验**（部署版 start.sh）：stop（日志 "CVM stopped using
   SIGTERM"）→ weread-dyn → killall(TERM) → framework start（cvm 新 PID 恢复）→ 回 home。
   退出弹窗重启的崩溃面已移除，待用户 KUAL 实测确认。

### 交用户复验清单

- KUAL>微信读书>启动微信读书：应**白底黑字**主菜单
- 打开《我为什么写作》：正文正常（封面页显示"[图片页]"占位）
- 阅读中 Menu/ScreenKB+Down：暂仍开目录（快捷菜单 UI 下批）；ScreenKB+Up=目录
- 退出：framework 干净重建回主屏，**不应再弹"发生错误"**

## 2026-11-20 · 首轮交互验收修复（7 项用户实证 → 4 修复 + 2 确认 + 1 误判纠正）

**用户真机报告 7 项，逐条核实：**

| # | 报告 | 核实结论 | 处置 |
|---|---|---|---|
| 1 | 黑底白字，应白底黑字 | **真 bug**：K4 einkfb 灰度=墨量语义（0x00=白/0xFF=黑），UI 层假设反了（与 Duokan 量化"墨量 0..15"语义自洽——当初极性假设错误） | ✅ UI 四件色值对调 + 自检改判亮 |
| 2 | 翻页正常 | ✓ 键位/EVIOCGRAB/章节续读链路验证 | — |
| 3 | 书本乱码，图片无显示 | **真 bug**：用户读的书（3300070895）是 **epub 排版**，t_0 txt 分片对它不适用（probe_fmt 取证 e_0=base64('<?xml…')）；图片=简版口径未实现 | ✅ 格式探测（e_0 JSON=txt / xhtml=epub）+ html_text.lua 剥离器（图片→[图片]占位） |
| 4 | ScreenKB+Down/Menu 打开的都是目录 | **真 bug**：三键全绑 toc（keymap 文档定义 Menu/ScreenKB+Down=快捷菜单、ScreenKB+Up=目录） | ✅ KEY 拆分 + 快捷菜单待实现 action="quickmenu"（menu.lua 下批） |
| 5 | 书架慢/显示不全/只有测试书？ | **非 bug**：10185 本全部有标题（全量书架含公众号/连载，非只有测试书）；慢=gateway 全量 JSON 在 K4 解码；"显示不全"=1700 页翻不完 | 📋 后续：分类过滤（books/archive/albums/mp）+ 首页提示 |
| 6 | 同步进度/设置无内容 | **占位项**（menu.lua show 占位）——DK-3/DK-4 后续实现 | 📋 确认 |
| 7 | 退出弹窗"发生错误"，设备马上重启 | **真 bug（用户实证纠正了我的误判）**：cvm SIGSTOP/CONT 生命周期崩（framework 弹窗+cvm 重启；整机 uptime 连续未清零——framework 级重启）。我的首轮取证用了过时快照且把"未查到"当"没发生"，向用户道歉 | ✅ start.sh/recover.sh 改 framework 整体 stop/start（koreader.sh --framework_stop 同款），消除 cvm 半停态崩溃面；真机生命周期验证 ✓ |

### 附加发现（测试抓出）

- **Lua 模式无 `|` 交替**：html_text 块级标签 `(p|div|…)` 是逐字面匹配（全不命中）→ 逐标签多趟。
- run.lua 契约：suite 须返回失败计数（os.exit 会吞汇总行）。
- 布局不变式校验器：行中 tab 跨折行边界时逐行 trim 会假阳性 → 用"非空白序列一致"。

### 状态

- 12 套 host 测试绿、双变体构建零错（13f2c01）。
- 设备第四次掉线（部署未确认完成）→ 恢复后 `tools/deploy-weread.sh` 全量重部署 +
  KUAL 实测复验（极性/快捷菜单/epub 正文/退出无弹窗）。
- 快捷菜单 action="quickmenu" 的 UI（三选一：继续阅读/章节目录/退出阅读）待实现（下批）。

## 2026-11-20 · KUAL 启动无反应修复（DK-4 提前落地：启动器三件 + 真机生命周期验证）

**目标**：用户报「KUAL>微信读书>启动微信读书，无反应」。

### 根因

`/mnt/us/extensions/weread/menu.json` 是 **isword 0.3.9 遗留**（Nov 4 日期，铁律不改它），
"启动微信读书"action=`sh /mnt/us/weread/start.sh` → **文件不存在**（isword 部署从未包含/
已被清理）→ KUAL sh action 静默失败。三项 action 全部断链。

### 机制取证（不改发明，全部有出处）

- KUAL 执行机制（k4weread.sh 注释）：点击后 KUAL 自杀退出（onStop）→ 脚本经 MKK su
  后台执行，stderr→/var/tmp/KUAL.log，cwd=扩展目录 → 脚本直接前台跑应用即可。
- framework 处理（koreader.sh K4 默认路径）：**framework 保留，cvm SIGSTOP 防盖屏**，
  退出 SIGCONT + appmgrd 回主屏——不 stop framework、不碰 rc5（铁律），完全可逆。

### 动作

1. `kual/bin/{start,diagnose,recover}.sh` 三件补齐断链（menu.json/config.xml 原样不动）：
   start.sh=防重复启动+cvm SIGSTOP+weread-dyn menu.lua+退出恢复+回 home；
   diagnose.sh=只读报告；recover.sh=人工兜底。`tools/deploy-kual.sh` 部署（本仓 kual/ 入 git）。
2. **真机生命周期验证**（模拟 KUAL 后台执行）：
   - start.sh → weread-dyn 起（2 个 event fd=输入独占）+ cvm State:T(stopped) + fb md5 变化（菜单上屏）
   - killall(TERM) → app exit rc=143（进程内 wr_cleanup 恢复原屏）→ cvm State:S(sleeping) → 回 home
   - 全链路可逆，无残留。日志 /mnt/us/weread/data/start.log。

### 交付状态

KUAL 三项全部指向有效脚本。**用户可实测**：KUAL>微信读书>启动微信读书 → 主菜单；
键位手感验收（docs/keymap-k4.md §五）随该路径一并完成。

## 2026-11-20 · 设备复跑：审查修复真机验收全绿（折行渲染/renew/dk3/菜单）

**目标**：设备第四次上线，验证代码审查修复在真机上的行为。

### 动作与结果

1. **凭据先行备份**（硬约束）：auth.json.bak-review。
2. **全量部署**（含审查修复版 reader/input/json）→ 菜单 SMOKE PASS。
3. **dk3_smoke：0 failure(s)**——catalog 15 章、batch=5 章真实正文（2691-3096 字节）、
   缓存命中不重下、进度回环——审查修复未破坏数据面。
4. **🔴折行修复真机渲染验证**（新增 reader_render_smoke.lua）：真实章节（3300235630 ch3）
   → Reader.layout（真 freetype 测量）→ 89 行布局回环 OK + 首页像素黑笔画 PASS。
   排障注记：首轮回环 MISMATCH 是校验器假阳性（行中 tab 恰跨折行边界，逐行 trim 把它
   剥了）——布局不变式改为「非空白字符序列一致」后 PASS，**折行本身无 bug**。
5. **renew_smoke：0 failure(s)**——目录/psvts/续期后 3030 字节真实正文：凭据门禁与
   续期在审查修复后行为不变。
6. menu SMOKE：PASS（PIXEL-CHECK/ft=on）。

### 待办（唯一设备项，交用户）

- **键位手感交互验收**（跨五批未做）：`tools/deploy-weread.sh --interactive`，
  按 docs/keymap-k4.md §五逐条：书架选书 → RPgFwd/LPgFwd 翻页 → 章末续读 →
  Left/Right 换章 → ScreenKB+Up 目录 → Menu 快捷菜单 → Back 退出 → 继续阅读回位。
  若 ScreenKB 粘住（组合键不释放）：latch 800ms 超时释放已实现，观察是否还需调参。

## 2026-11-20 · 独立代码审查（orbital_handoff RESUME + ub-mode + code-review-skill）

**目标**：接手 DK-3 现状（后续会话已推进：会话生命周期/续期/测试体系），全量代码审查并修复。

### RESUME 核查

- 上一份交接（dk2-download-reader-code-ready）判 VERY_STALE：**历史被改写**（09a3a57 不可达）
  且后续会话推进了 DK-3（dk3_smoke 假绿修复=net.c 丢响应头、会话生命周期/renewal、键位改造、
  11 套主机测试）。以链头 dk3-login-persistence-device-recheck（STALE 2.9h）为准接手。
- 基线：10 套测试全绿、双变体构建零错。设备第三次掉线（ssh 判据，ping/扫段不采信）。

### 审查范围与发现（逐文件）

| 级别 | 位置 | 发现 |
|---|---|---|
| 🔴 | reader.lua wrap_line | 字节 pos 与字符计数混用→中文行超宽折行切进 UTF-8 字符中间（乱码/空行风暴）。ASCII 恰好 1B=1char 而漏过既有测试。 |
| 🟡 | input.c mod latch | handoff 预案未落地：code 29 不报 release → 修饰键永久粘住。 |
| 🟡 | json.write_atomic | tmp+rename 有但无 sync——本批实测三次掉电，rename 后 page cache 未回写即断电会丢凭据/进度。 |
| 🎉 | api.lua 门禁/副本合并、net.c 头收集修复、progress.lua 单写者、auth.lua 续期分类器 | DK-3 新增面质量高，测试钉住到位。 |
| 🟢 | net.c | 内存安全干净（栈平衡/无泄漏/无越界）；UA 双设无害（HTTPHEADER 覆盖）。 |

### 修复（TDD 红绿）

1. 🔴 wrap_line 重写为**字符域贪心**（utf8_chars 切分 + measure 依赖注入 + 单字符超宽强制收行）
   + tests/wrap_test.lua 8 断言（回环不变式/切字/超宽单字符不死循环/空行/单字符/混合宽度）。
   红绿两轮：测试自身两处初稿错误（假测量恒 10 不随长度、rows 计数笔误）修正后绿。
2. 🟡 input.c：`wr_mod_expired(now_ms, press_ms)` 纯函数（>800ms 过期）+ struct 加 mod_press_ms
   + poll 开头超时清零 + press 记时刻/release 归 -1 + WR_INPUT_TEST_MAIN 3 断言
   （新增 EXPECT_INT 宏）。红绿 sanity（断言故意写反必须红）确认断言真实执行。
3. 🟡 json.write_atomic：rename 后 os.execute("sync")（写频低，秒级阻塞可接受）。

### 回归证据

- `lua5.1 tests/run.lua` → **LUA-TESTS-OK (11 suite(s))**（wrap_test 收编，改返回计数契约——
  初稿误用 os.exit 会吞掉汇总行）
- `make weread && make weread-dyn` → 0 error；`make host-selftest` → HOST-OK + INPUT-OK（含 latch 红绿）
- 未 push（仓库 public，push 需用户点头——沿用上批纪律）

### 待办交接

- 真机：键位手感交互验收（唯一挂着的设备项，跨五批）+ 设备恢复后全量部署复跑 11 套
- 设备掉线次数已 3 次：DK-3 稳定性阶段建议给 progress/auth 落盘加「写前备份 auth.json.bak」双份滚动

## 2026-11-19 · 签名面：先判定「哪种测试不值得写」，再补摘要已知答案 + 真机跨架构取证

**目标**：继续测试剩下的无断言生产面。第一个候选是签名面（`protocol.lua` → `sign()` → md5/sha256），
因为它决定服务端收不收我们的上报/正文请求。

### 动作

1. **差分测试在这条路上不值得写**：`diff <(sed 's/weread\.lib\.//g' 插件的 protocol.lua) src/lua/lib/protocol.lua`
   只差注释 + 一处 `math.randomseed` 播种（那是端口时遗漏 nonce 播种的修复，本仓刻意加的）。
   逐字节相同的两份代码做差分，证明的是「同一份代码等于它自己」——0 信息量，不写。
   位置换算那边值得写，是因为端口重写过函数形状（`position_of` vs `local_to_remote`），不是复制。
2. **改打标准**：新增第 10 套 `tests/crypto_test.lua`（known-answer，12 样例 × 2 摘要）。
   期望值取自 RFC 1321 A.7 与 NIST FIPS 180-2，并用本机 GNU `md5sum`/`sha256sum` 逐个复核——
   基准是标准与独立实现，不是我的算术、也不是插件源码。边界挑在填充点上：
   63/64/65（MD5 block 边界）、119/120（SHA-256 长度字段跨字节）、256 全字节（含 NUL 与控制字符）、
   CJK 多字节、1e6 字节（长度字段 64-bit 拼接）。
3. **趁设备在线把同一份样例搬上真机跑**（`WR_CRYPTO_SLOW=1`，含 1e6）：`crypto: 12 样例 ×2 摘要，CRYPTO_EXIT=0`。
   这才是这件事的价值所在——**摘要在 250MHz ARM LuaJIT（-joff、glibc 2.12.1）与 x86 结果一致**，
   主机测试永远证明不了这一条，而签名是在设备上算的。
   一次性脚本放设备 `/tmp`（tmpfs），没进仓库也没进 `/mnt/us/weread`；设备随后第三次掉线，
   那份 4KB 临时文件会随重启消失，无需人为清。
4. **变异验证 + 还原纪律**：把 md5 初始向量 `a0` 改 1 bit → 11 条 md5 FAIL、**0 条 sha256 FAIL**
   （两条判据各自独立且都活着）。还原用今天的教训：`cp` 自己的副本 + `cmp` 核对，
   **不用 `git checkout --`**（上一条批次里它把未提交的修复冲掉过一次）。

### 验证

`make host-lua-test` = **10 套绿** + `CRED-WRITERS-OK (3)`；真机同一份样例 exit 0。
提交 53af2b5。设备第三次掉线（`No route to host`，判据只用 ssh 本身）；唯一还挂着的真机项
仍是键位手感交互验收，它需要有人站在设备前按键。

### 状态

`origin/main` 之上待推：53af2b5。未观测路径不变：`Auth.renew` 的真实 `expired` 分支——别接回扫码。

## 2026-11-19 · 两处「注释里的规则」被测试拆穿：position_of 与参照实现差分、Api.request 就地合并反向放行

**目标**：继续测试。设备在线窗口先跑掉 Q3（见下一条），剩下的时间给「主机侧一直没被钉住的
生产面」——挑的不是新功能，而是**只有注释在守、没有断言在守**的地方。

### 动作

1. **先问「期望值是谁算的」**：`report_position_test.lua` 11 组全绿，但每条期望都是我手算的。
   手算只证明「符合我对公式的理解」，证明不了「符合参照实现」——而本仓与插件写的是服务端
   **同一组 co/pr**，标定又证明服务端原样存、不从 co 反推 pr，两边一旦漂移，用户在插件与本
   客户端之间切换就会被写偏位置。
   于是新增第 8 套 `tests/position_golden_test.lua`：期望值由 `lua5.1` 直接调用插件
   `position_mapper.local_to_remote()` 产出（`tools/gen_position_golden.lua` 生成
   `tests/position_golden_vectors.lua`，重跑逐字节一致，provenance 可复现）。
   4 本目录形态 × 页码网格 = **agree 323 点 + plugin_refused 34 点 + gated 60 点**。
2. **三类行判据分开，刻意漂移要写成正向断言**：参照实现对 `words<=0` 的章直接报错，本仓
   **刻意继续**（前言/空白章不该让整本停止更新）——这条差异如果不钉住，下一个人「对齐插件」
   就会把它改回去。所以钉两点：该章偏移必须恒为 0（words=0 ⇒ 章内不可能推进）、
   同章跨页 percent 必须不变。gated 行仍带着参照实现当时会算出的 off/pct，作为
   「我们**没有**把哪个错误位置发出去」的证据。
3. **第 9 套 `tests/api_jar_test.lua` 一跑就红，而且红得比预想严重**：`Api.request` 里
   「已有会话只接受合并后仍是可用会话的 2xx」这条规则被自己的实现拆穿了——
   `Cookie.merge_set_cookie` 是**就地**改传入表（空值=删除），`merged` 与 `auth.cookies`
   是同一个引用。收到 `wr_skey=` 时先被掏空的是调用方那份活 jar，于是
   `not has_login_cookie(auth.cookies)` 变成 true，门禁把「会话刚被清空」读成
   「本来就没会话、不受此限」→ **掏空后的 jar 原样落盘**。后果正是用户明令禁止的那条：
   登录态没了只剩扫码（有风控风险）。
4. **修法用同一条边界纪律，不新增写入口**：合并前先 `Cookie.sanitize` 出一份新表（与加载期
   同款），判定用改前那份 jar；顺带治第二个缺陷——新增 `Cookie.equal`，只在合并结果与原 jar
   **不相等**时才写盘。此前每个 2xx 响应都重写一次 auth.json：磨闪存，而且「谁在什么时候改了
   凭据」根本无从回答。写入口计数仍是 `CRED-WRITERS-OK (3)`。
5. **8 场景先红（4 FAIL）再修；变异验证三条判据都咬得住**：改回就地合并 = 8 FAIL；
   `jar_usable` 强行 true = 场景 1 FAIL；删掉 changed-only 条件 = 场景 8 FAIL；
   位置差分：round→floor = 149 FAIL、删拒发线 = 60 FAIL、照参照实现那样对 words<=0 拒答 = 68 FAIL。
   每次都 md5 核对还原。**操作教训**：我用 `git checkout --` 当变异还原手段，把还没提交的
   修复冲掉了一次（HEAD 里没有它）——未提交的改动只能 `cp` 出副本再还原。

### 验证

主机 `make host-lua-test` = **9 套绿** + `CRED-WRITERS-OK (3)`；`make host-selftest` = HOST-OK + INPUT-OK。
真机（`api.lua`/`cookie.lua` 两端 md5 对账后部署）：`dk3_smoke` 0 failure、`renew_smoke` 0 failure
（force→`replaced`、`wr_rt` 28 未丢、第二次被冷却挡住）、`read_report_smoke` 0 failure
（`co=1908 pr=96` 回读逐字节相同、`jar items 6->6 header_unchanged=true`）。全程未扫码。

### 状态

`origin/main` 之上待推：5883e75（位置差分套件）、5ed52cb（会话合并门禁修复）+ 本条 LOG。
仍未观测的路径不变：`Auth.renew` 的真实 `expired` 分支——**在它被观测之前不要把 expired 接回扫码**。

## 2026-11-19 · DK-3.5 阅读上报落地：签名面真机被收下，位置逐字节落盘（零位移验收）

**目标**：设备在线而键位验收需要人，就趁这个窗口把 DK-3 之后唯一不需要人按键的项做完——
`read_report`（原语 `make_read_payload` 自 DK-2 起就是零调用方）。

### 动作

1. **先取证语义**（不猜协议）：插件 `weread/lib/position_mapper.lua:186-209` 定下两条换算——
   `chapterOffset` 是**章内字数偏移**（以目录 `wordCount` 为上界，不是字节数），
   `progress` 是 `(前序章字数 + 本章偏移) / 全书字数` 四舍五入到整数点；
   `weread/lib/reader_state.lua:29-31` 证明 psvts/pclts/token 三件本应从同一张 reader 页一起抽。
   端点只有 `POST /web/book/read`——没有独立的 setprogress，位置随时报一起落。
2. **架构取舍：不做心跳**。插件是 30s 心跳 + 调度器 + 积压补报；本客户端单进程无异步，
   心跳会把网络请求打进翻页关键路径（K4 弱网一次往返数秒，手感直接变卡），且规律定时流量
   在服务端是风控面（与「UA 必须同源」同一个道理）。改成**离开一章时发一次**，
   `rt` 取该段墙上时间并夹到 30s（服务端只吃小步 rt，大值被静默丢弃）。
3. TDD：`tests/report_position_test.lua` 先跑红（`module 'report' not found`）再实现
   `src/lua/report.lua`。8 组断言里三条是「必须失败」的：章不在目录时不得悄悄按第 1 章上报
   （那会把服务端位置拽回开头）、`wordCount=0` 不得除零、越界页码必须夹进合法区间。
4. **减法优先**：不新增凭据写入口——上报走已受门禁的 `Api.request`，`CRED-WRITERS-OK (3)` 未放宽；
   不动 `reader.lua`（`sm` 摘要留空，代价只是服务端「最近阅读」少一句片段，不值得为它加一条页首行回传）。
   `download.fetch_psvts` 只加**第三个返回值**（整份 reader state），老调用点与
   `dk3_smoke` 的按名计数都不受影响。
5. **动网络前先备份**：`auth.json` → `auth.json.bak-report`（设备 data 下第 4 份备份）。
6. **验收件刻意做成零位移**（`src/lua/read_report_smoke.lua`）：上报用的是**服务端当前的位置**
   而不是本地进度，所以不挪用户的阅读位置；报完回读 `/book/getprogress` 对账，因为只断言
   `accepted` 会被「回 succ 但不写」糊过去（net.c 那次假绿的教训）；选书只挑「服务端已有位置」的第一本，
   找不到就退出而不是造假数据。
7. 真机结果（首跑 `read_report smoke: 0 failure(s)`，8 项全 PASS）：`sg`/`s` 签名面被收下
   （token 从 reader 页实抽，29 字符）；`ci=15 co=1908 pr=96` 回读**逐字节相同**；
   `pclts` 该书页面上没有 → 沿用插件的 `e(now)` 兜底，不算失败；
   本地字数换算与服务端 percent 相差 3 个点（99 vs 96，页码取整方向所致），在容忍内
   ——**此句已被下一条推翻**：那条比对用的基准（服务端 co 是字数）本身不成立，见
   「2026-11-19 · 标定推翻「在容忍内」」。
   如实记一条：这次验收带了 `rt=30`，服务端该书的阅读时长统计多了 30 秒（位置未动）。

## 2026-11-19 · Q3 标定收口：拒发线只挡 5.3%，章序兜底只补 1/8 → 不加兜底

**目标**：设备恢复到线（前一轮判为「第二次真离线」），把唯一压在待办上的真机测量跑掉——
拒发线 `Report.MIN_AVG_WORDS` 挡掉了书架的多少本，以及「改用章序百分比」兜底能不能替上。

### 动作

1. **精准同步而不是整份部署**：只 scp `src/lua/*.lua` + `src/lua/lib/*.lua` 并 `md5sum` 两端对账
   （`report_calib.lua`/`report.lua` 各自一致），不跑 `deploy-weread.sh` 的 SMOKE 尾——
   设备在线窗口是稀缺资源，别把时间花在已经验过的渲染上。动网络前 `auth.json` → `auth.json.bak-q3`。
2. **结果（`sampled=151 / skipped=0`，150s 预算内采满）**：Q1 `co>wordCount` 86/151、
   Q2 可判定 37 点里 2 点自洽（与前两轮 97/171、91/160 与 2/43、2/40 同向，结论复现）；
   **Q3 `GATED=8/151`（5.3%），章序百分比兜底只补得上 1 本，另 7 本与服务端 pr 差 >5 点。**
   这 8 本的共同形态是目录 `wordCount` 为占位值（每章 1~4 字，`total` 123~138）。
3. **按预先写好的判据收口，不临场改标准**：判据是「`GATED` 个位数 → 保持拒发」，命中。
   更深一层：兜底把「不同步」换成「按错误位置同步」，而 Q2 已证明 `pr` 是被服务端原样记住的字段——
   写偏一位就是用户进度被写坏，**代价不可逆、收益只是让 8 本占位目录的书看起来在同步**。
   决定不写这条兜底代码，也不为它写测试；把答案连同「再跑本脚本是复核不是取证」写进脚本头注释。
4. **复核「只读」这个我自己立的前提**：标定号称一次都不写服务端，但 GET 路径也可能触发续期写凭据。
   用 Lua 层指纹（cookie 名 + 值长度 + `has_login`）对 `auth.json` 与 `auth.json.bak-q3` 比对：
   `CRED-DIFF UNCHANGED items=6 has_login=true->true`。值一个都没打印。
5. **顺手抓到一个会咬人的环境事实**：第一版比对脚本用 `arg[1] or 默认路径`，返回 `decode_failed`。
   我先怀疑 `"rb"` 模式，探测证伪（`r`/`rb`/`rt` 三种模式读同一文件都 272 字节，`/dev/urandom` 的
   `read(4)` 也正常）；再探 `arg` 本身，实测 `argc=3, arg[0]=脚本路径, arg[1]=脚本路径, arg[2]=第一个真参数`，
   而 `...` 是 `nil`。→ **设备上的 Lua 里 `arg[1]` 不是第一个参数，是脚本名**；
   此前记录只说了「不给 `...`」，害我把脚本源码当 JSON 解析了一遍。

## 2026-11-19 · 标定推翻「在容忍内」：co 不是服务端语义；-2012 是无心跳设计的常态

**目标**：上一条里我用「相差 3 个点，在容忍内」结案了一个**没验过的假设**——上报位置的单位。
接线一跑就会写进用户手机端的进度，假设错了是可感知的损害，所以这一轮只做一件事：把它量出来。

### 动作

1. **写标定件 `src/lua/report_calib.lua`（纯只读，一次都不写服务端）**：对书架每本带服务端
   进度的书取 `(ci, co, pr)` + 目录字数，看本仓换算能不能解释服务端的真实数据。
2. **第一版设计是错的，先拆自己**：首跑 171 本被我本机 `timeout 240` 掐死在书架中途；
   更要紧的是我把 co 与「由 pr 反解的偏移」直接比差——`pr` 服务端只到整数个百分点，
   1 个点对应 `total/100` 字，对十万字的书容差天然巨大，**这项检查对大多数书根本不可能失败**。
   重做成两个可判定性不同的问题：Q1「co 会不会超过本章 wordCount」（与 pr 无关，硬证据）、
   Q2「pr 能否由 co 推出」（只在 `0<pr<100` 且 `total/100 <= 本章字数` 时可判，其余记 NA 而不是 OK），
   加 150s 网络硬预算并打印样本量。
3. **标定结论（两次独立采样：171 本 / 160 本）**：
   * `co > wordCount` 的书 **97/171 与 91/160**——服务端存的 co 不是「章内字数」，且不校验、原样存；
   * Q2 可判定点 **43 个里 2 个、40 个里 2 个**自洽 → **服务端不由 co 反推 pr**，co 与 pr 各存各的。
   * 于是「字数偏移」是**客户端之间的约定**（本仓与插件互认，与手机端靠 pr 互认），不是服务端算法；
     推论有两条：① 任何读路径不得反解服务端 co（`grep chapterOffset` 复核：生产路径确实只写不读）；
     ② pr 算错会被**直接记住**，所以换算不可信时必须拒发而不是发出去再看。
4. **标定顺带抓到会真伤用户的形态**：不少书的目录 `wordCount` 是占位值（整本每章 1~4 字，
   `total` 只有 138）。拿这种目录换算，主机实测把一本服务端 `pr=97` 的书算成 **`percent=8`**。
   TDD 先红（3 条失败，其中一条直接打印出那个 8）再实现：`Report.MIN_AVG_WORDS = 20`，
   平均每章不足 20 字即 `nil, "catalog_words_unusable"`——本地进度照旧，只是不发这一枪。
   另两组（每章 60~80 字的薄目录仍要能报、个别 `wordCount=0` 的前言章不得拖整本拒答）钉住这条线不画宽。
5. **真机 `-2012` 取证 + 修根因**：本轮首跑 `read_report_smoke` 回 `errCode=-2012 status=200`，
   而几十秒前 GET 全通（calib 读了 160 本）。插件判据：`read_report.lua:173-180`——
   会话没了就用 -2012/-2013 回答（HTTP 仍 200），`:118` 的对策是「续期 + 重试一次」。
   跑 `renew_smoke`（`wr_skey` 轮换）后同一条上报立刻被收下。**根因在本仓自己的设计**：
   刻意不做心跳 → 一章读完再报时 skey 常常已过龄，所以 -2012 是常态路径而非异常。
   实现照插件：`Report.send` 遇 -2012/-2013 → `Auth.renew()`（**非 force**，它自带的 600s 冷却
   就是重试上限）→ `replaced` 才重试，且只重试一次。传输层失败不续期（凭据未知，不许猜会话已死），
   其它 errCode 不续期（参数被拒续期也没用）。
6. `tests/report_retry_test.lua`（8 场景，先红 7 条再绿）把这些行为钉成断言：恰好一次续期一次重试、
   冷却中绝不重试、重试上限一次、-2022 与网络失败零续期、`NO-PSVTS` 仍在任何请求之前拦住、
   续期绝不带 force。
7. **删掉自己写的假绿**：`read_report_smoke` 原第 3 组拿**服务端的 co** 折成页码再比 percent，
   而 `co/words=1.87` 被 `math.min(10, …)` 夹成末页——那条 PASS 恰恰是反例被吞掉的结果。
   换成夹不出一致的判据：真机目录上 page 1..10 逐页可算、随翻页单调不减、始终落在 0..100
   （设备实测 `92% -> 99%`，服务端 96 落在其中）。
8. 纪律与坑：动网络路径前 `auth.json` → `auth.json.bak-calib`；`${PIPESTATUS[0]}` 是 bashism，
   设备走 `sh -c` → 语法错误让一次 calib 白跑，管道尾巴改在本机做。

### 验证

- 主机：`make host-lua-test` → **7 套全绿** + `CRED-WRITERS-OK (3)`（自愈复用 `Auth.renew`，
  没有新增凭据写入口）；`luac -p` 全过；红→绿可复现（位置门 3 红、重试 7 红）。
- 设备：`PIXEL-CHECK PASS`；`read_report_smoke` **11 项全 PASS**（零位移，offset/percent 回读对账）；
  `dk3_smoke` 0 failure；`renew_smoke` 0 failure；`report_calib` 两次采样 exit 0，结论一致。
- 全程未扫码；`wr_rt` 28 字符全程未丢。

### 状态

DK-3.5 的发送面现在对两类真实故障免疫：目录字数不可信（拒发）、skey 过龄（续一次重试一次）。
`chapterOffset` 的语义按证据降级为「同约定客户端之间的提示」，`progress` 是唯一跨客户端位置字段。
仍待办：键位手感验收需要人人在设备边按键（`tools/deploy-weread.sh --interactive`）。

### 排查记录：`cmp` 把我误导成「凭据被删」，真判据在 Lua 层

1. 我写「`auth.json` 与备份逐字节相同 ⇒ 会话没被动过」，实测 `cmp -s` 全部 **DIFF**，
   第一反应是 `Set-Cookie: wr_rt=`（空值删除）把 refreshToken 吃掉了——那等于只剩重扫码。
2. 逐条查下来两个结论都与猜测相反：
   * 备份之间本来就该不同（`bak-recheck`→`bak-report` 之间跑过一次 `renew(force)`，
     轮换 `wr_skey` 并补发 `wr_pf`，5 项 → 6 项）；
   * **`Json.encode` 的键序随 `pairs` 抖动**，同一份会话也能比出 DIFF。
     `cmp` 只能证「字节序列不同」，永远不能证「凭据增减」——这条判据从一开始就是错的。
3. 权威读数用 Lua 层：`Cookie.sanitize` 后取**条目名 + 值长度 + has_login_cookie**，
   当前盘面 `n=6 [wr_fp=10 wr_pf=9 wr_ql=1 wr_rt=28 wr_skey=8 wr_vid=8] login=true`，
   与 `bak-report` 完全一致 → 上报路径（含其响应）没有改动 jar 内容。
   我那条 BusyBox grep 之所以显示 5 项，是因为 `tr ',' '\n'` 把含逗号的 cookie 值切断了；
   **BusyBox 文本切分不是会话读数**，别再用它判 cookie 数量。
4. 把结论做成机器断言：`read_report_smoke.lua` 增第 4 组——跑完一遍必须
   `has_login==true` 且 `wr_rt >= 8`（丢了就只剩重扫码），并把 `header_unchanged`
   作为信息打印（合法轮换会改它，所以不断言相等，只断言会话仍可用）。
5. **一条纪律违例，如实记录**：我为查值长度写的 `awk -F\"` 字段序号写错，把若干条 cookie
   的**真值打印到了本机终端**。值只出现在本机这次会话输出里，未进任何文件、提交、交接文档；
   正确写法就是上面第 3 条（名字 + 长度 + 布尔）。以后探测凭据盘面一律走 Lua 层指纹，
   不在 shell 里切 JSON。

### 验证

- 主机：`make host-lua-test` → 6 套全绿 + `CRED-WRITERS-OK (3)`；`luac -p` 全过；先红后绿可复现。
- 设备：`tools/deploy-weread.sh` → `PIXEL-CHECK PASS`；`read_report_smoke.lua` 加上会话不变量组后
  复跑 **10 项全 PASS**，其中 offset/percent 两条是**回读对账**而非请求返回码，
  `header_unchanged=true` 证明上报路径没动 jar。
- 会话不变量：`Api.has_login()` 与 `Cookie.has_login_cookie` 全程 true，`wr_rt` 28 字符未丢。
- 全程未扫码。

### 状态

DK-3.5 的服务端写入面已打通并证明落盘。两处待办：① `menu.read_book` 里的接线只做了静态核对
（`Report.send` 入参形状与 `sess.psvts/pclts/token` 来源），它要随键位手感验收在同一次真实阅读里
跑到——那需要人按键；② 本批与之前各批的提交仍未 push，等用户点头。

## 2026-11-19 · 真机验收跑绿：续期=replaced、正文可用；并更正「设备离线」是我的探测写错

**目标**：用户指出「真机一直在线」，把持久化批次唯一未取证的一项（免扫码续期真机复测）跑完，
顺手清掉本会话遗留在设备上的探测脚本。

### 动作

1. **前提更正（这是本批最重要的发现）**：`tools/k4-env.local.sh` 里 `K4_HOST` 的值已含
   `root@` 前缀，所以我用来判「在线/掉线」的 `bash -c 'exec 3<>/dev/tcp/$K4_HOST/$K4_PORT'`
   打的是 `/dev/tcp/<K4_HOST-host>/2222` —— 无效目标，稳定报 `No route to host`，
   被我当成设备离线，还挂了个 10 分钟的轮询监视器去「等它上线」。改用 `ssh -o ConnectTimeout`
   一试就到了认证阶段，设备一直在线。
   另一面也要分清：本批更早的 `ssh` 确实真失败过，设备 dmesg 里
   `Battery: Resume - TimeSuspended(secs)=2435` 印证它真睡了约 40 分钟。**两种「连不上」原因不同，
   判据只能是 ssh 本身走到哪一步**（路由不通 / 认证失败 / 通了）。
2. 先按纪律备份：`auth.json` → `auth.json.bak-recheck`（数据目录现共 3 份备份，都在设备上）。
3. `tools/deploy-weread.sh` → `PIXEL-CHECK PASS`、`EXIT=0`（Lua 层不内嵌在二进制里，
   deploy 的 scp glob 就是分发路径，所以新增脚本无需重编）。
4. `dk3_smoke.lua` → `0 failure(s)`：5/5 章有真实正文（bytes 17/293/3096/2946/2691，longest=3096），
   缓存重跑 0 次网络调用。
5. 新增并跑通正式验收件 `src/lua/renew_smoke.lua` → `0 failure(s)`：
   `renew(force)` 回 **replaced**；`jar_items` 5→6（服务端补发 `wr_pf`）、`wr_skey` 仍 8 字符、
   `wr_rt` 28 字符、**前后 `has_login` 都 true**；不带 force 的第二次 = `cooling`；
   续期后走 t_0 取到 3030 字节正文。**门槛 16→8 的校准由真机确认，不再只是探测推断。**
6. 清场（先验无凭据值再删）：9 个 `probe_*.lua`、`evsniff`、`data/poll_raw.json`、
   `data/login_run.log`（`grep -ci token` = 0，只含已被消费掉的二维码 uid）。
7. 提交 37f8cb9（renew_smoke + 真机证据写进 commit body）。

### 验证

- 设备侧三条命令全绿：`dk3 smoke: 0 failure(s)` / `renew smoke: 0 failure(s)` EXIT=0 / `PIXEL-CHECK PASS`。
- 主机侧未回归：`make host-lua-test` → 5 套 + `CRED-WRITERS-OK (3)`；`make host-selftest` 绿。
- 全程**未触发扫码**，登录态未被破坏（这正是本批要证明的不变量）。

### 状态

DK-3 只剩一项：键位手感交互验收（`tools/deploy-weread.sh --interactive`，需要人在设备边按键；
重点验 ScreenKB 组合键与 code 29 是否报 release）。本批 + 上批的提交仍未 push，等用户点头。
下一批的可达性判据请直接用 ssh，别再拿 `/dev/tcp/$K4_HOST` 当探针。


## 2026-11-19 · 免扫码续期 + 会话持久化（照 weread_K4 插件补齐登录生命周期）

**目标**：用户指示「不要扫码，可能触发风控，需要参考原 weread_K4 插件，做好登录的持久化」。
上一批修完 `net.c` 丢响应头之后，`set-cookie` 首次真正进入 Lua——于是「任何响应都合并落盘」的老
设计开始反复吃掉登录态。这一批解决的是会话生命周期，不只是补一个 renew。

### 动作

1. **唯一一次扫码**（按用户要求，之后不再）：`Auth.login` 走通，落盘后立刻检查 refreshToken 是否留存。
2. **写盘路径审计**：全仓只有三处会写 `auth.json` —— `Api.request`（当时是无条件合并+落盘）、
   `Auth._complete`、新增的 `Auth.renew`。第一处就是「重登一次又被探测脚本清空」的机制，也是风控面上
   最危险的一处：一次匿名响应即可作废整个 jar。
3. **cookie 条目门禁**（`src/lua/lib/cookie.lua` 新增 `is_session_name` + `sanitize`）：名称只允许
   `wr_*` 加 ptcz/RK/pgv_pvid，值不得含 `;`/控制字符、上限 4096 字节；幂等（合法 jar 过一遍不变）。
   删除语义（`name=` 空值）保持标准行为——安全性挪到调用层，而不是改契约。
4. **根因**：`auth.lua` 的 `jar_request` 把扁平 jar 当 `auth` 传给 `Api.request`，而后者约定
   `auth = {cookies=…}`，于是 `auth.cookies = merged` 在 jar 里写出一个名为 `cookies` 的伪 cookie 并
   跟着 Cookie 头出站。源头改 `opts.auth = { cookies = jar }`，另在 `Api.load_auth` 边界一次性
   sanitize 作纵深防御（插件 credential_store 加载期复校同款）。真机已验证该伪条目消失。
5. **单一写入口**（`src/lua/api.lua`）：只有「2xx 且合并后仍是可用会话」才写盘——判据用
   `Cookie.has_login_cookie` 对新旧 jar 各算一次，因此登录中途（还没有会话）不受限制、合法轮换照常
   生效，而降级/匿名响应不再触盘。
6. **只读派生请求**（`src/lua/download.lua fetch_psvts`）：reader 页不再合并响应 cookie、不再落盘；
   同时补上 UA——此前不带 UA 落到 `net.c` 默认 `WereadK4/0.1`，与正文 POST 的 Edge UA 在同一会话里
   呈现两种客户端身份，插件 `migrations.lua:11` 明确把这列为风控触发面。
7. **`wr_rt` 留存**：`poll_once` 从拼接串改为返回凭据表（带 refresh），`_complete` 把 `refreshToken`
   urlencode 后存进 `cookies.wr_rt`。此前直接丢弃 → web 域一过期只能重扫（正是用户要避免的事）。
   真机 `wr_rt` 28 字符已在盘。
8. **免扫码续期**（`src/lua/auth.lua` 新增纯函数 `classify_renewal` + `renew`）：四态
   `network / expired / replaced / stale`。只有 `replaced|stale` 增量收紧落盘（过 `is_session_name`），
   失败分支什么都不改——插件 `client.lua:692-710` 纪律：network/stale 绝不清凭据，只有真 expired
   才允许要求重扫。冷却 600s，被动续期不打成心跳。
9. **空分片自愈**（`src/lua/download.lua`）：`EMPTY-SHARD` 由「静默返回空」改为硬失败 → 触发一次
   `Auth.renew()` → 重试。会话过期的表现从「整本书只剩标题」变成「续期一次后拿到正文」。
10. **断言硬化**（`src/lua/dk3_smoke.lua`）：批 3→5，`spool has content` 换成
    `spool has real chapter body`（正文须明显长于标题）。缺的正是这条断言，才让上一轮 8/8 假绿。
11. **门槛校准**：插件的 16 字符门槛在本机全线误报。裸探测（`/tmp/probe_renew.lua`，一次性脚本）显示
    `status=200 body={"succ":1}` 且轮换回来的 `wr_skey` 只有 **8** 字符——续期其实成功，是被照搬过来的
    阈值判死。改 `Auth.RENEW_MIN_SKEY_LEN = 8` 与 `has_login_cookie` 同源，并加测试禁止两者在
    「会丢活会话」的方向上不一致。
12. **不变量复查抓出残留写入口**：按「谁写 auth.json」逐行 grep，发现 `Api.authenticated_get` 在
    `Api.request`（已受门禁）之后又自己 `merge_cookies` + `save_auth` 一次——一次带空值 Set-Cookie 的
    响应照样能绕过门禁清空会话；而它全仓零调用方（登录走 jar_request，书架走 Api.gateway）。整段删除，
    凭据写入口收敛为三处且全部经过判定：`Api.request` 门禁分支、`Auth._complete`、`Auth.renew`。
13. **把不变量做成机器门槛**（`Makefile` host-lua-test）：`Api.save_auth` 调用点数必须恰好等于 3，否则整条
    Lua 门禁红牌并打印「合法写入口是哪三处 + 为什么」。**双向验证过**：现状 3 处绿；临时插入第 4 处未受判定
    的写盘点后立即失败（`CRED-WRITER-GUARD: Api.save_auth 调用点 4 处，应为 3`），复原后回绿。
    理由：这条纪律靠 grep 记忆不可靠，下一批 agent（或我）新增落盘点时不会先想起它。

### 验证

- 主机 5 套全绿：新增 `tests/cookie_test.lua`（名/值门禁、幂等、Path/Domain 忽略、按名删除、门槛）与
  `tests/renew_test.lua`（9 组四态 + 冷却下限 + 门槛同源）。
- 真机（改阈值前）：jar 名 `wr_fp wr_ql wr_rt wr_skey wr_vid`；伪 `cookies` 条目消失；`has_login` true；
  取章 2814 字节 HAS-BODY；`renew()` 之后 `has_login` 仍 true（凭据没被吃掉——这条是本批的核心不变量）。
- **未竟**：阈值修正后的真机 `renew()` 复测（期望 `replaced` 且 `wr_skey` 轮换落盘）——设备已掉线
  （`no route to host`），主机侧已复核但真机结论留待下一批。

### 状态

代码 + 测试就绪（本批 5 个提交 a59da13→115dc3e），未 push。待办：① 设备上线复测 `renew()` = `replaced`；② 键位手感验收
（`tools/deploy-weread.sh --interactive`）仍未做；③ 探测脚本仍留在设备 `/mnt/us/weread/lua/`，
`auth.json.prelogin-1910` / `bak-1926` / `pre-renew-test` 备份待用户决定去留。


## 2026-11-19 · 真机验收发现正文为空 → 修掉 net.c 两个响应头 bug（会话cookie从不刷新）

**目标**：用户告知 K4 上线，要求「进行必要的测试」，把 DK-3 积压的真机数据面验收跑完。

### 动作

1. **离线门槛复绿**后部署：`make host-selftest`（量化 + input 组合键）、`make host-lua-test`（3 套）、
   `tools/deploy-weread.sh`（`PIXEL-CHECK PASS`），再跑 `dk3_smoke.lua` → 末行 `0 failure(s)`。
2. **没有采信这个绿**：spool 下来的 3 章只有 8/14/66 字节——全是标题。扩面到 8 本书取第 5 章，
   `fetch_chapter_text` 一律返回 **0 字节正文**，确认是会话级而非单书级问题。
   → `dk3_smoke.lua:79` 的 `spooled > 0` 只验证「文件存在」，标题级缓存即可满足 → **验收假绿**。
3. **排除法定位**：`make_content_params` 与参考插件逐字节相同（diff 只有 require 路径与 randomseed）→
   不是参数/签名；对照端点经同一路径返回 2.7KB 404 页面 → 不是 body 捕获；
   `t_0` 的 `status=200 bodylen=0` 是服务端真的给了空分片。
4. **根因一**（`src/device/net.c:55`）：`on_header` 早退条件 `total > 6`——本意是给
   `memcmp(line,"HTTP/",6)` 限长防越界，实际把**每一条真实响应头**全部丢弃，`set-cookie` 到不了 Lua。
   改为 `(total >= 6 && memcmp(...) == 0)`：既保住短行，也不越界读状态行前缀。
5. **根因二**（`src/device/net.c:268`）：响应头入表时 `lua_gettable` 已弹走 key，收尾又把 key 压在
   value 之上，而 `lua_settable` 要求栈序 `[..., tbl, key, value]` → 实际写成 `tbl[值] = 名`
   （现象：`nginx/1.16.1: server`）。改为 `pushkey; pushvalue(key); gettable(-3)`，两个分支统一收尾
   `settable(-3)`。`hdrs["set-cookie"]` 此前恒为 nil。
6. **代价与教训**：`set-cookie` 合并首次真正生效后，服务端下发 `wr_vid=`/`wr_skey=`（空值），
   `lib/cookie.lua:46` 按标准语义正确地删除了它们 → 设备上登录态失效（无备份，已无法回滚）。
   会话早已名存实亡（这正是 bug 的表现），但**把过期落盘的直接触发者是我反复跑的探测脚本**：
   动网络路径前应先备份 `data/auth.json`。本轮起固化为习惯，已在重登前补 `auth.json.prelogin-1910`。
7. 旧 spool 整体挪至 `/mnt/us/weread/books.stale-1843`（未删）；`evsniff` 交叉编译推上设备，
   确认三个输入节点均未被 grab（event0 tequila-keypad / event1 fiveway / event2 volume）。

### 验证

- 修复后 `probe_pairs.lua`：`KEY=[server] VAL=[nginx/1.16.1]`、`content-type`→`text/html; charset=utf-8`，
  同名头追加语义正常（`vary` = 两行 `Accept-Encoding`）——键值不再颠倒。
- 修复后 8 本书第 5 章正文：**531 / 2069 / 14333 / 9262 / 4213 / 1123 / 2284 / 15795 字节，全部 HAS-BODY**。
  正文链路自 DK-2 起首次真正打通（此前阅读器渲染的一直是空数据）。
- `make weread-dyn` 重建零警告；`make host-selftest` / `host-lua-test` 仍全绿。

### 状态

已修已提交（net.c 两处）。待办：`wr_rt` 缺失（`auth.lua:186` 丢弃 `refreshToken`，web 域轮换 skey 后
无法续期）→ 本轮重登后验证；`dk3_smoke` 断言需改为要求正文长度、`fetch_chapter_text` 需对空分片报错，
否则这类故障继续静默通过；键位手感验收因 60s 采集窗口内无人按键仍未完成。


## 2026-11-19 · git 历史改写：从全部提交中清除内网设备地址（force push 已获授权）

**目标**：用户指示「用 git filter-repo 清除历史里的旧 IP 并 force push」。上一批只清了 HEAD，
已公开的历史提交里设备地址真值仍在（199 处命中）。

### 动作

1. **范围审计**：`git grep` 全历史扫 RFC1918 模式 → 只有一个内网地址、199 处、跨 38 个提交；
   没有第二个内网 IP。
2. **先备份**：`git bundle create /home/doro/backups/WereadK4_BasedDK-pre-filter-20261119.bundle --all`
   + `git bundle verify`（"records a complete history"，170K）。改写不可逆，回退全靠它。
3. **不在工作仓里跑 filter-repo**：`vendor/`（61M 多看资产）、`build/`（16M）、`handoffs/`（196K）、
   `tools/k4-env.local.sh` 都是 gitignore 的不可再生本机资产，而 filter-repo 收尾会 reset/gc——风险不值得。
   改在 `git clone --no-local` 出的临时仓里跑（第一次漏了 `--no-local`，被 filter-repo 拒：本地 clone 不算 fresh clone）。
4. **替换规则**：`--replace-text`，单行「真值`==><K4_HOST>`」（filter-repo 默认按字面匹配，无需 `literal:` 前缀）；
   占位符与 HEAD 现行写法一致，历史条目读起来仍通顺。真值本身只存在于本机 `tools/k4-env.local.sh`，不写进本文件。
5. **改写后逐项验证**（见「验证」），确认无误才动工作仓。
6. **工作仓换头**：`git fetch <临时仓> refs/heads/main` + `git checkout -B main FETCH_HEAD`
   —— tracked 内容零变化（HEAD tree hash 不变），ignored 资产完好（vendor/build/handoffs 尺寸复核一致）。
7. **推送**：`git push --force-with-lease=refs/heads/main:<改写前 SHA>`——lease 钉住审计过的远端状态，
   远端若被别人动过就拒绝，比裸 `--force` 安全。第 1 次尝试即成功（代理这轮没抽风）。
8. **本地清尾**：`git reflog expire --expire=now --all && git gc --prune=now` → 旧对象（含真值）从本机仓库消失
   （`git cat-file -t <旧SHA>` 报 not found）；临时 clone 与替换表文件删除。
9. **修复被改写打断的 SHA 引用**：历史改写让所有 SHA 变号，`AGENTS.md`/`LOG.md` 里 17 处引用会指向不存在的提交。
   从备份 bundle 取旧历史，按 subject 逐条对齐（38↔38，`diff` 全等）建映射，精确替换 12 个被引用的 SHA；
   `docs/` 里那个 7 位十六进制的固件 SHA-256 前缀（`07a2238…`）不在映射表内，未被误伤。
   `AGENTS.md` 的指针行顺手去掉钉死的 SHA（每提交都过时，这次改写正好证明它脆弱）。

### 旧→新 SHA 映射（引用旧号的笔记/交接按此换算）

| 旧 | 新 | 提交 |
|---|---|---|
| af3c702 | 247d897 | DK-3 输入层: ScreenKB 修饰键 latch |
| 216a6d8 | 2e7054e | DK-3 进度存储: progress.lua + Json.write_atomic |
| 0df7c75 | ab517c6 | DK-3 下载侧: 按需补章 + 批量预取 |
| d88bdbf | b3e28a2 | DK-3 阅读器: 键位对齐 + 跨章 action 信号 |
| a42d1cf | 2ad8908 | DK-3 菜单: read_book 循环 + 目录 + 续读 |
| fa69a41 | da53ffc | DK-3 验收: dk3_smoke.lua |
| a5e6b61 | 76c85c3 | DK-3 文档: keymap-k4.md + LOG |
| 07a7561 | a630b2f | AGENTS.md: handoff 指针 → dk3 kit |
| f5bc76f | ec914a2 | AGENTS.md: 状态更新（远端已建） |
| 9672af5 | 3101774 | 公开仓库卫生整改 |
| 9a8b1e9 | d7cbf42 | LOG: 公开发布批次 |
| 147c543 | cc213b1 | DK-2 后半: download/reader/menu 级联 |

### 验证

- 改写仓：全历史 `git grep` 内网网段零命中；**HEAD tree hash 与改写前逐字节相同**（`8e1d6b3c…`）→ 发布内容未被动；
  38 提交、subject 列表、author/date 列表与原历史 `diff` 全等；138 个 blob 落上 `<K4_HOST>` 占位符。
- 远端：`git ls-remote origin` = `d7cbf42` = 本地 HEAD；`gh api commits?per_page=100` = 38；
  `forks=0 / watchers=0`（无派生仓残留旧历史）。
- 引用修复后：12 个旧 SHA 全仓 `git grep` 零命中；12 个新 SHA 逐个 `git log -1 --format=%s` 与预期主题一致。
- 回归：`make host-selftest`（HOST-OK + INPUT-OK）、`make host-lua-test`（3 套件 0 failure）。

### 状态 / 残留

- **GitHub 侧仍可按旧 SHA 直取**：`gh api repos/.../commits/<旧SHA>` 仍返回 200——force push 只改分支可达性，
  悬空对象要等 GitHub 自己的 GC。要立刻彻底清除需联系 GitHub Support，或删仓重建
  （本仓 forks=0、watchers=0、无 issue/PR，删重建代价很低）。
- 备份 bundle 在 `/home/doro/backups/`（含改写前完整历史与设备地址真值）——**本机 only，勿上传**。
- 设备仍离线，DK-3 真机验收继续阻塞。

## 2026-11-19 · 公开发布 + 公开仓库卫生整改（设备仍离线）

**目标**：用户两条指示——①「本机已有 GH 授权，直接推送为项目，公开」；②「执行 1 和 2」
（= 我报告的三点公开可见项里的前两点：内网设备地址、指向本机 `~/reports/` 的死引用；第三点 LICENSE 留给用户决定）。

### 动作

1. **发布前审计**（推送会把 35 个提交全部公开，先审后推）：tracked 文件清单逐个过（50 个，全是源码/文档/测试/工具）；
   枚举历史上曾 add 过的所有路径——无 `auth.json`、无 `vendor/`、无 `handoffs/`、无二进制；
   全历史密钥正则扫描（`wr_skey=`/`wr_vid=`/`api_key=`/PRIVATE KEY/`ghp_`/`ssh-rsa`/`password=`）零命中；
   `WeRead.DEFAULT_READER_TOKEN`（`src/lua/lib/protocol.lua:18`）与公开上游插件
   `weread.koplugin/weread/lib/protocol.lua:7` 逐字节相同 → 是上游硬编码值，不是用户凭据。
2. **建仓并推送**：`gh repo create WereadK4_BasedDK --public --source=. --remote=origin --push`。
   仓库建成但 push 失败——本机 gost 代理（127.0.0.1:10800）对 `github.com:443` 不稳：
   HTTP CONNECT 返回 503（约 15s 后）或 TLS 中途被断（`GnuTLS recv error (-110)`），
   socks5h 也只偶发成功，直连超时；而 `api.github.com` 稳定 200（所以 `gh` 能用）。
   连续 ~20 次失败后**重试即通**——不改配置，只循环重试（写法已记进 handoff 的 Blocker 段）。
3. **指针状态更新**（ec914a2）：`AGENTS.md` 原文「git push（仓库无 remote）双阻塞」在公开后成了假信息，
   补 Remote 行并把 Status 改为「仅剩设备阻塞」。
4. **设备地址移出仓库**（3101774）：`deploy-k4.sh` / `deploy-weread.sh` 改为
   「环境变量 > `tools/k4-env.local.sh` > 报错退出」，删掉硬编码默认值；新增 `tools/k4-env.example.sh`
   （只有变量名与占位符）；`tools/k4-env.local.sh` 进 `.gitignore`；
   `AGENTS.md`/`LOG.md`/`dk3_smoke.lua` 里的字面 IP 换成 `$K4_HOST` / `<K4_HOST>`。
5. **本机文档引用标注 local-only**（3101774）：README 增「构建与部署」段（明说不入库的构建依赖：
   `~/x-tools` 交叉工具链、`vendor/`、`~/k4-sysroot`，以及设备地址配置步骤）；
   `Current Handoff` 段改为说明 `handoffs/` 本地 only；`docs/duokan-k4-driver-architecture.md`
   证据源表下加注（表内路径均为本机材料，结论已抄进文档，读者不需要原文件）。
6. **未做**：git 历史重写。IP 与旧引用仍存在于**已公开的历史提交**里，从 HEAD 清掉不等于从历史清掉；
   清历史要 `filter-repo` + force push（或删仓重建），属不可逆操作 → 交用户决定。

### 验证

- 审计：`git ls-tree -r --name-only origin/main` 敏感路径扫描（handoff/auth.json/vendor/*.so/*.zip/*.pem/.env）零命中。
- 整改：`git grep` 内网网段正则（`192.168.` 段全模式）全仓零命中；`git check-ignore -v tools/k4-env.local.sh` 命中 `.gitignore:12`；
  `bash -n` 两脚本通过；**用 stub ssh/scp 跑三种配置情形**——本机文件被 source、`K4_HOST`/`K4_PORT` 环境变量覆盖生效、
  两者皆无时报出带指引的错误（测行为不测实现）；`luac -p dk3_smoke.lua` 通过。
- 回归：`make host-selftest`（HOST-OK + input combo selftest OK）、`make host-lua-test`（3 套件 0 failure）全绿。
- 远端：`git rev-parse HEAD` == `origin/main`；仓库 public。

### 状态

- 2 个提交（ec914a2、3101774）+ 本条 LOG。仓库 https://github.com/dororo42/WereadK4_BasedDK 已公开。
- 设备仍离线（`.151` ARP FAILED、ping 不通；未做全网段端口扫描——被安全策略拦下，也不该扫）。
  → `dk3_smoke.lua` 真机验收与键位手感验收**继续阻塞**，仍是 DK-3 唯一未了结项。

## 2026-11-19 · DK-3 阅读侧：键位对齐 KOReader 习惯 + 批量下载 + 断点续读（设备仍离线）

**目标**：用户两条要求——① 继续 DK-3（阅读侧优先、章末自动续读）；② 参考 weread_K4 插件快捷键，
保留该使用习惯。

### 动作

1. **键位习惯溯源**：插件的键位不是它自定的，而是 KOReader 在 K4 上的默认——插件只劫持四处
   （`ScreenKB+Down`/`Home`/`Menu`/`Back`，`reader_navigation.lua:18-161`）。权威表在插件
   `README.md:70-88`：`Left/Right`=换章、`LPgFwd/RPgFwd`=下一页、`LPgBack/RPgBack`=上一页、
   `Press`=底部菜单、`Menu`=顶部菜单、`Back`=关闭、`Home`=书架、`ScreenKB+Up`=目录。
   我们 DK-2 的 reader 把 `Right/Down/Press` 当翻页、四个 bezel 翻页键一个没绑——直接冲突。
2. **C 层修饰键 latch**（247d897）：`wr_input_poll` 原本丢弃 release，Lua 侧看不到修饰键抬起。
   latch 放 C（键位语义本来就在 `input.c` 决策，不下沉 Lua 造成分裂），产出 KOReader 同款
   `ScreenKBPlus<Key>`；latch 挂 `struct wr_input`（跨设备：code 29 在 event0，D-pad 在 event1），
   且排在通用 release 过滤之前（否则抬起被丢 → 修饰键粘住）。主机自测 `WR_INPUT_TEST_MAIN`。
3. **进度存储**（2e7054e）：`lib/progress.lua`（原子写、损坏降级为空、book_id 一律 tostring 作键）；
   顺手把 `api.lua:save_auth` 里手写的 tmp+rename 抽成 `Json.write_atomic` 共用（消除重复）。
4. **下载侧**（ab517c6）：`is_spooled`（空文件不算缓存）/`chapter_pos`+`find_chapter`
   （服务端 chapterIdx 不连续，与数组下标不能混用）/`new_session`+`ensure_chapter`
   （psvts 每书抽一次、懒取；命中缓存零网络请求）。**不做批量预取**：单进程无异步，
   预取只是把同样的等待提前到开书时（拖慢首页），改为章切换时按需下载 + 「准备章节」屏。
5. **阅读器**（b3e28a2）：键位表导出为 `Reader.KEY_*` 模块字段（改键位不动控制流，且可主机单测钉住）；
   跨章动作以 `action` 信号交回调用方；`start_page` 负数 = 从末页开始（回退上一章用）。
6. **菜单**（2ad8908）：`read_book` = 全项目唯一跨章决策点（目录→进度起点→按需取章→渲染→
   每次离章即 `Progress.set`→按 action 分派）；`pick_chapter` 目录列表（末项「退出阅读」，
   快捷菜单与目录共用一屏）；「继续阅读」接 `Progress.get_last()`。
7. **验收**（da53ffc）：`dk3_smoke.lua` 用 `count_calls()` 包装 `fetch_psvts`/`fetch_chapter_text`
   计数，直接断言「重跑 0 次网络请求」，不用计时阈值猜测。
8. **文档**：`docs/keymap-k4.md`（对齐表 + 两处刻意偏离 + 组合键实现 + 未接绑定的组合键清单）。

### 验证

- 离线全绿：`make host-selftest`（quant HOST-OK + input combo selftest OK）、
  `make host-lua-test`（progress / download_pure / reader_keys 三套 0 failure）、
  `luac -p` 全量、`make weread` + `make weread-dyn` 交叉编译零新警告。
- 真机待跑（设备离线）：`dk3_smoke.lua` + `--interactive` 键位手感验收。
  **唯一离线不可验的假设**：真机 evdev 上 code 29 的 press/release 是否成对出现
  （若只报 press，修饰键会粘住 → 需在 C 层加超时自动释放）。

### 状态

- 6 个提交（247d897 → da53ffc）。推送仍阻塞：仓库无 remote，需用户给远端地址。
- 两处刻意偏离（`Up/Down` 降级为翻页、`Press` 保留翻页）均一行可翻转，
  `tests/reader_keys_test.lua` 会强制同步断言——真机手感不对时改这两处即可。

## 2026-11-19 · 离线代码审查修复批次（ub-mode + code-review）

**目标**：全量审查 C 设备/桥接层（~1626 行）+ Lua 协议/加密/业务层（~3507 行），修复其中可离线完成的缺陷。无 🔴 阻断级；核心协议/加密层质量高（已由可工作的登录+书架链路实证）。

### 动作（分级审查 → 修复 5 处）

1. 🟡 **信号安全**（wrmain.c / wrbridge.c / wrbridge.h）：原 `on_signal` 调 `wr_cleanup → wr_ft_done → FT_Done → free()`，`free` 非 async-signal-safe；Ctrl+C 打断 malloc 会死锁/坏堆且屏幕不恢复。新增 `wr_emergency_restore()`（仅 memcpy/ioctl/fsync/close 级恢复），信号路径改调它，正常退出仍用完整 `wr_cleanup`。逐一核实 `wr_input_close`(ioctl+close)/`wr_fb_restore`(memcpy)/`wr_fb_refresh_full`(ioctl)/`wr_fb_wait`(fsync) 均无 malloc/free。
2. 🟡 **header 截断**（net.c）：HTTP 头定长 `char item[1024]`+`snprintf` → 长 Cookie/Authorization 静默截断致鉴权失败且无线索。改按 `klen+vlen+3` 堆分配手工拼接，`curl_slist_append`（内部拷贝）后立即 `free`。
3. 🟡 **auth 原子写**（api.lua）：`save_auth` 就地覆写 auth.json，掉电/kill 中断 → 截断 → `Json.decode` 失败 → 用户被登出。改「先编码 → 写 .tmp → 同分区 rename」，写/rename 失败即 `os.remove(tmp)`；并删除无效 no-op `os.rename(path,path)`（注释名不副实，既不建目录也不校验）。
4. 🟡 **shard 奇数守卫**（shard.lua）：`reverse_swaps` 步长 -2 成对消费 positions，奇数个 → i=1 时 `positions[0]=nil` 算术崩溃。入口加 `#positions%2~=0 → error`（fail-fast；`Shard.decode` 已被 download.lua pcall，异常转干净解码失败）。奇偶性证明：`swap_positions` 恒返回偶数（成对插入 + 第二插入守卫在循环条件成立时必然成立）→ 守卫为纯防御、对真实解码路径零回归。
5. 💡 **PRNG 播种**（protocol.lua）：全树无 `math.randomseed` → nonce（r / rn / ts）跨运行恒定、可预测。比对参考插件（/home/doro/weread_K4.koplugin）确认其 `main.lua:28 init()` 调 `math.randomseed(os.time())`，本仓端口 protocol.lua 时遗漏该播种。改在 protocol.lua 加载时播种一次（require 缓存保证仅执行一次；「生成 nonce 的模块自带播种」，不依赖宿主入口）。

### 验证（设备离线，本地静态 + 行为测试）

- `luac -p`：api / shard / protocol 全通过。
- 交叉编译 `-Wall -Wextra -fsyntax-only`（wrmain / wrbridge / net）零警告；`make weread` + `weread-dyn` 全量链接成功（7MB 静态 / 3MB 动态 ARM EABI5，唯一告警是 LuaJIT lj_clib.o 既有的 static-dlopen 提示，与本次无关）；`make host-selftest` HOST-OK。
- **api.lua 行为测试**（加载真实模块，host lua5.1 + bit）：往返保存/读取（含 UTF-8 账号名）+ 覆盖写 + 无残留 `.tmp` = T_API_OK。
- **protocol.lua 行为测试**：两进程相隔 >1s（不同 os.time 种子）→ nonce `r` 不同（111556 vs 15389929），且 `make_content_params` 输出结构（b/c/ct/ps/r/s）不变 = 播种生效且无回归。

### 状态 / 未做（需真机，或判定为过度工程）

- 设备仍离线（No route to host）。以上均可离线验证；`download_smoke` 真机验证待 K4 恢复上线。
- **延后**：💡 menu.lua stringly-typed 分派（按中文标签字面量比较）、🟢 忙等自旋（auth/login/shelf/menu 多处 `while millis()-t0<N do end`）—— 二者均改设备侧 UI/输入行为，离线无法证伪，且现有代码已在真机跑通（登录+书架），遵循「不重构无法验证的工作代码」，待设备恢复再做。
- **跳过**：🟢 render.c 负 pitch / pixel_mode 防御 —— `FT_LOAD_RENDER` 恒返回正 pitch + GRAY，加校验违反「不为不可能场景加防御代码」；🟢 auth.lua `dofile`→`require`（qrencode 绝对路径更健壮且为冷路径）；🟢 json.lua null 语义（当前业务未触及，改动有回归风险）。

## 2026-11-19 · 复用 vs 自编译评估 + handoff 固化（设备仍离线）

**目标**：用户决策问题（复用多看 vs 重新编译，哪个更贴合/收益更高）+ 当前状态 handoff。

### 动作

1. **评估落地** `docs/tech-decision-reuse-vs-recompile.md`：结论=现状双变体混合已是收益最优
   （渲染/UI 自编译 + 网络层复用 libcurl），复用是过渡态（TLS 老化/CVE/绑定 glibc 2.12.1），
   自编译不省 TLS 大坑；网络层失效预案 runbook 化（weread TLS 握手失败=唯一触发信号）。
   多看自有组件（KindleApp/dkkernel）判死维持——复用甜点区=OSS 成品运行库+字体数据。
2. **handoff** `dk2-download-reader-code-ready`（READY）：DK-2 后半代码完成（download/reader/menu
   级联，cc213b1），download_smoke 待设备恢复；上份交接三项全部给出结局；设备离线 blocker 记录。

### 状态

- 设备仍离线（No route to host）。设备上线后首跑 download_smoke（见 handoff 下一步 1）。
- 本批次无代码变更（纯文档/交接）。

## 2026-11-19 · DK-2 后半：download.lua + reader.lua 完成（真机 smoke 待设备恢复）

**目标**：DK-2 余项——章节下载 + 阅读器 + 菜单级联全实现。

### 动作

1. **插件 content.lua 管线还原**：目录=gateway /book/chapterinfo（Bearer）；正文=GET reader 页抽 psvts（正则兜底）→ make_content_params（protocol 已有：b/c=WeRead.e 加密+s 签名）→ POST /web/book/chapter/t_0(+t_1) → **shard 解码链**（32 字符 MD5 前缀校验 + 字节二进制→4 进制换位表 reverse_swaps + URL-safe base64）→ 纯文本。e_*/tar（epub/图片）简版不含。
2. **lib/shard.lua 移植**（纯 Lua 分支，去 FFI——静态 exe 无动态符号）。
3. **download.lua**：catalog（normalize 三形态展开）/fetch_psvts（cookie 带 jar）/fetch_chapter_text（t_0+可选 t_1，JSON 错误体识别）/spool（books/<id>/<idx>.txt，BusyBox mkdir）。
4. **reader.lua**：freetype 26px 排版——UTF-8 二分折行（protocol.utf8_substr + font_width 贪心）、段落空行布局、五向翻页（Right/Down/Press 前翻，Left/Up 后翻，Back 退）、页脚进度；fb/input 生命周期归调用方（menu 级联共享）。
5. **menu.lua 级联**：书架选书 → clear_screen"下载章节中" → Download.book(首章) → Reader.open → 回菜单。
6. **download_smoke.lua**：全自动验证（书架第一本 → 目录 → 2 章下载 → spool 预览）。
7. 笔误修复：download.lua Json 未定义引用、`not type(x)=="table"` 逻辑反。

### 状态

- 全部 luac 语法通过。**真机 download_smoke 未跑**：scp 阶段设备掉线（No route to host，
  疑似休眠断 WiFi/被拿走），重试 4 次×15s 未恢复。设备上线后：
  `tools/deploy-weread.sh` 然后 `ssh … ./weread-dyn lua/download_smoke.lua`。

### 风险点（smoke 首跑重点看）

- psvts 正则抽取（__INITIAL_STATE__ 大 JSON 的正则兜底路径是否命中）
- t_0 shard MD5 校验（协议参数/时间戳偏差会在这里暴露）
- 未购书 errCode（shelf.books[1] 可能是不可读条目——脚本只报错不选书，交互模式用户选书更可控）

## 2026-11-19 · DK-2 登录+书架全链路打通（真实账号登录成功，书架 10181 本）

**目标**：登录正式入口 + 菜单级联 + 书架视图；用户实际扫码打通登录态。

### 动作

1. **login.lua 正式入口**（QR→扫码→成功屏+书架验证）、**shelf.lua 书架列表**（gateway /shelf/sync → 中文列表 + 分页 + 五向键导航，SMOKE 像素自检）、**menu.lua 级联**（登录/书架项接线，标题显示账号名）。
2. **json.lua 数字解析 bug 修复**（扫码登录凭据丢失根因）：`string.find` 无捕获组时 Lua 5.1 只返回两值，`local _,e,num = find(...)` 的 num 恒 nil → 所有 JSON 数字值静默丢失（webLoginVid 数字型凭据消失）。修复=模式加捕获组；api_smoke 补数字回归用例。
3. **手机端"扫码失败"根因修复**：缺 **wr_fp 设备身份 cookie**。auth.lua 重写为插件 login_cookies 语义：独立 cookie jar（wr_fp=urandom 4 字节持久化 + skills 页预热 + 各步 Set-Cookie 合并），成功才落盘；api.lua 加 no_save 开关支持登录中途不写盘。
4. **排除项**： salvage 第 2 轮会话（手工 auth.json + vid/skey）→ userInfo 层活但 apikeyGet 401（缺完整 jar）→ 证实必须走完整预热流程。
5. 部署脚本升级为全量 lua 推送。

### 真机验证（PASS）

- **扫码登录成功**（账号 32819470）：手机端确认成功 → LOGIN_SUCCESS → userInfo → apikeyGet → auth.json 落盘
- **gateway /shelf/sync：10181 books**（登录态验证达标）
- 书架列表屏 SMOKE：`shelf pixel-check header=0`（真实数据渲染）
- 调试过程证据链：poll_raw.json 落盘定位字段缺失 → DBG print 定位 json 数字 bug → 本地单测修复后一次通过

### 遗留与下一步

- 用户交互验收：`tools/deploy-weread.sh --interactive`（菜单五向键 + 书架翻页选择；Back 返回）
- download.lua 章节下载 + reader.lua 阅读器（DK-2 后半，方案 §五）
- 10181 books 含公众号/出版物等混合条目，shelf 视图分类过滤待做（对照插件 shelf 结构 books/archive/albums/mp）
- NEED_OTP 短信验证码输入（K4 无键盘 UI，暂不支持，提示先网页版登录）

## 2026-11-19 · DK-2 业务层基础设施：API/登录 11 项真机验证全 PASS

**目标**：DK-2 业务层第一波——网络扩展 + 协议层移植 + 登录流程 + 自动验证。

### 动作

1. **插件源研究**（/home/doro/weread_K4.koplugin/weread/lib/）：发现 v9.x 已迁 **gateway 模式**——登录后 apikeyGet 拿 key，数据 API 走 POST i.weread.qq.com/api/agent/gateway + Bearer（方案 §4.3 旧 Cookie 直连表过时）；protocol.lua 纯 Lua 可原样移植（sign/e/web_app_id）；QR 非图片而是本地编码器（qrmessage），登录 URL=/web/confirm?uid=；NEED_OTP=新设备短信验证码状态。
2. **net.c 扩展** `http_req(opts)`：method/headers/body/响应头收集（同名头 \n 拼接，Set-Cookie 多值语义）；坑：LuaJIT pushfstring 不保证 %.*s，改纯栈 concat。
3. **纯 Lua 四件移植**（铁律标注来源）：crypto.lua（MD5/SHA256）/protocol.lua（改 require 路径）/cookie.lua/qrencode.lua（speedata/luaqrcode MIT，本地验证 29×29 矩阵）。
4. **自研 json.lua**：decode/encode，\u 代理对→UTF-8，主机 roundtrip 测试过。
5. **api.lua**：auth store（/mnt/us/weread/data/auth.json）/cookie 注入/Set-Cookie 合并/gateway Bearer/401×3 重试（插件同款）。
6. **auth.lua**：QR 登录全流程——getLoginUid→QR 屏（fb 块渲染+量化）→0.5s 轮询（Back 取消/过期自动重取 uid 重画）→userInfo→apikeyGet→存盘；NEED_OTP 给出明确指引（K4 暂不支持验证码输入）。
7. **wrmain** 加全局 arg 表（标准 Lua 语义）；deploy 脚本全量 lua 推送、BIN 默认 weread-dyn。

### 真机验证（PASS 11/11）

- MD5 已知向量 abc/空串、sign/e 格式、cookie 合并、json 往返
- **getLoginUid 返回真实 uid**（登录链路无凭据可调，TLS+JSON+头全通）
- gateway 无 key 本地守卫、userInfo 未登录 401 结构化
- **QR 屏渲染 finder 像素自检 PASS**（黑块确凿，屏显 5s）
- api_smoke 首败两例：arg[1] 是脚本路径（标准 arg 语义）→ 遍历判断；QR 采样点忘加 quiet 偏移 → 修

### 下一步

用户实际扫码登录（屏上 QR + 手机微信）→ 登录态拉书架（gateway /shelf/sync）→ shelf.lua/download.lua/reader.lua（方案 §五 DK-2 余项）。扫码前需确认账号已开通微信读书 Skill。

## 2026-11-19 · DK-1 完成确认 + DK-2 网络层打通（动态变体 + 复用多看 libcurl TLS PASS）

**用户确认**：DK-1 交互之前已验证——DK-1 全部完成。
**DK-2 拍板执行**：首选路线（复用多看 libcurl 动态变体）一次打通。

### 动作

1. **最小动态链接实验**：experiments/dyn/dyn_hello.c 用 TC(gcc14) 编码 + `-L~/k4-sysroot/lib` 链接设备 glibc 2.12.1；产物 interpreter=/lib/ld-linux.so.3，最高符号版本 GLIBC_2.4；设备实跑 EXIT=0——动态变体技术前提全验证。
2. **复用资产抽取**：多看 libcurl.so.4.3.0（curl 7.29.0 + OpenSSL 1.0.1e 内嵌，1.9MB）→ vendor/duokan/lib/（NOTICE 已标注，部署名 libcurl.so.4）；curl 7.29.0 头文件从 GitHub tag 取（curl.se 归档 URL 已失效）。
3. **手工 curlbuild.h（armel）**：SIZEOF_LONG=4 / curl_off_t=long long(64bit)，**必须含 dist 尾部的两个 typedef**（curl_socklen_t/curl_off_t）——漏了会报 curl_off_t undeclared（首败根因）。
4. **网络层三件**：`src/device/net.c`（curl_easy 最小面：http_get，VERIFYPEER 开/FOLLOWLOCATION/TIMEOUT 30/NOSIGNAL，body 动态缓冲）、`net_stub.c`（静态构建 no-op，桥接口不变）、wrbridge.c 的 wr_register 追加 wr_net_register 调用（静态/动态两态无差别）。
5. **Makefile weread-dyn 目标**：动态链接（无 -static），`-L~/k4-sysroot/lib`（libc 基线 2.12.1）+ `-l:libcurl.so.4.3.0` 精确名 + rpath `$ORIGIN/lib`。产物 3MB，NEEDED libcurl.so.4/librt/libdl/libgcc_s/libc，最高 GLIBC_2.7。
6. **链接坑两个**：① gcc 注入 `--sysroot`，**相对路径 -L 会被前缀到 sysroot 下**（首败）→ 全部绝对路径；② `-lcurl` 搜索名在 sysroot 语义下解析失败 → `-l:精确文件名`（ld 记 SONAME libcurl.so.4，运行期 rpath 命中）。
7. **部署脚本升级** `tools/deploy-weread.sh`：新增 weread-dyn/lib/net_smoke 部署 + `--net-smoke` 模式（一键部署+TLS 验证）。

### 真机 TLS 冒烟（PASS）

- `https://weread.qq.com/` → **status=200, 773KB**（VERIFYPEER 开启，设备 ca-bundle.pem 验签通过，复用 OpenSSL 1.0.1e）
- `https://www.baidu.com/` → curl rc=60（2015 时代 bundle 缺新根）——仅影响通用冲浪，业务域无关；**保持证书验证开启，勿关闭**。
- deploy-weread.sh --net-smoke 全链路复现 PASS（EXIT=0）。

### 下一步

DK-2 业务层（方案 §五）：auth.lua 扫码登录 / api.lua 签名移植（weread_K4 插件源 /home/doro/weread_K4.koplugin/）/ shelf / download / reader / sync。网络层基座（http_get）已就绪。

## 2026-11-18 · DK-1 step2 真机验收通过（freetype 中文渲染）

**目标**：DK-1 step2——freetype 接入，菜单升级中文。路线拍板：**上游 freetype 2.13.2 静态自编**
（复用多看 libfreetype 的动态变体归 DK-2 与 libcurl 一起做——届时反正要做 /lib sysroot；
静态自编在设备在线窗口外也零依赖，FreeType License=BSD 类可静态链接，NOTICE 标注）。

### 动作

1. **freetype 2.13.2 交叉静态编译**：`--host=arm-kindle5-linux-gnueabi --disable-shared --enable-static --without-{zlib,bzip2,png,harfbuzz,brotli}`（最小核心，TTF/TTC 渲染够用；ftgzip 自带内部 inflate 不需外部 -lz）。产出 4.5MB `libfreetype.a`（vendor/freetype，gitignored）。
2. **渲染层** `src/device/render.c/h`：FT_Init/FT_New_Face(face 0)/FT_Set_Pixel_Sizes（px 6~96 钳制）；UTF-8 手写解码器（1-4 字节，非法字节跳过）；字形混合 `dst=(dst*(255-cov)+fg*cov+127)/255` 背景透明；基线=y+ascender/64；行 stride=line_length、越界裁剪。最多 4 个并发字体句柄。
3. **桥扩展** `wrbridge.c`：`font_load(path[,px=28])` / `font_close(id)` / `fb_text_ft(id,x,y,utf8[,fg])` / `font_width(id,utf8)` / `fb_get(x,y)`（像素自检用）。wr_cleanup 统一 wr_ft_done。
4. **menu.lua 中文升级**：主字号 30 + 小字号 20；中文菜单项（继续阅读/书架/搜索/同步进度/设置/退出）+ 中文页脚；**点阵字体按次回退**（fb_text_ft 失败落 fb_text，缺字体文件整体回退 step1 英文模式）；draw() 加 fb_quant()（Duokan 量化收敛后再刷新）。SMOKE 增加**像素自检**（采样标题/首项/页脚区最小灰度，>200=字形区全白=失败）——无眼睛也可自动验收。
5. **SMOKE 容错**：input_open 失败不再 assert（KOReader EVIOCGRAB 独占时仍可自动验收渲染）；交互模式保持必须拿到输入。
6. **部署脚本** `tools/deploy-weread.sh`：weread+lua+字体（首次 5.2MB）三件部署，默认 SMOKE，`--interactive` 进交互。布局 `/mnt/us/weread/{weread,lua,fonts}`。
7. **DK-2 铺路（趁设备在线）**：设备 `/lib` 关键库归档 `~/k4-sysroot/lib/`——**实测设备 glibc=2.12.1**（2011-09-23），DK-2 动态变体的链接基线（TC 自带 glibc 更新，不可直接动态链接）。

### 真机验收（PASS）

- SMOKE：`ft=on`、pixel-check title=0 item1=0 footer=102（字形笔画确凿）、EXIT=0、dmesg 净、渲染后恢复原屏。
- 中文渲染全管线：UTF-8→freetype→8bpp 混合→Duokan 量化→0x46dd partial 刷新。
- 交互链路不变（step1 已验证五向导航）；KOReader 当前未运行，设备处于可交互状态。
- 构建产物 7MB 静态 exe（LuaJIT+freetype 内嵌），零代码警告（dlopen 链接注记为 LuaJIT 静态库既有无害产物）。

### 下一步

DK-1 收尾交互复验（用户侧：`tools/deploy-weread.sh --interactive`，五向键导航中文菜单）后即完成 DK-1，
进 DK-2 网络层：首选复用多看 libcurl+OpenSSL 动态变体（~/k4-sysroot 基线 glibc 2.12.1），
备选 OpenSSL 3.x 静态自编。

## 2026-11-18 · DK-1 step1 真机验收通过（LuaJIT VM + 输入独占 + 五向键菜单）

**目标**：DK-1 分阶段第一步——LuaJIT 2.1 armel 静态 VM + Lua C API 桥 + 内置点阵字体 + evdev 输入 + 五向键菜单，K4 真机可交互（freetype 中文渲染留 step2）。

### 动作

1. **LuaJIT 交叉编译**（最大风险项，已攻克）：vendor/luajit 2.1.1788856981，`HOST_CC="gcc -m32"`（buildvm 指针尺寸须匹配 32 位 ARM target，为此 apt 装 gcc-multilib/libc6-dev-i386）+ `LUAJIT_DISABLE_JIT`（K4/K5 JIT-on 定性崩）+ `BUILDMODE=static`。产出 `libluajit.a`（377KB），真机冒烟 LuaJIT 可跑（27KB 基线）。qemu binfmt 跑 buildvm 方案失败（老工具链 buildvm 在 qemu-arm 下 segfault），-m32 是正解。
2. **桥选型：Lua C API 而非 FFI**——静态可执行文件无动态符号表，`ffi.C.<sym>` 走 dlsym 解析不到；C API（lua_pushcfunction）静态/动态皆可。`src/bridge/wrbridge.c` 导出 `wr` 全局表：fb_open/close/w/h/refresh/fill/quant/text、input_open/close/poll、millis。
3. **设备层**：`src/device/input.c/h`（evdev event0=tequila-keypad/event1=fiveway，手工镜像 16B input_event 避 glibc time_t 歧义，键码取自 KOReader event_map_kindle4.lua）；`src/device/font8x16.h`（从 Uni2-VGA16.psf.gz 抽 95 个 ASCII 字形，PSF1 ASCII 直接索引 index==codepoint）；`src/host/wrmain.c`（LuaJIT VM 宿主，SIGINT/TERM 信号安全 cleanup）。
4. **menu.lua**：五向键 ASCII 菜单（Up/Down 移动、中键选中、Back/Menu/Home 退出），SMOKE 模式只渲染一帧即退（自动化验收）。Makefile 加 luajit/weread 目标，链接补 `-lrt`（老 glibc 的 clock_gettime 在 librt）。
5. **SMOKE 真机 PASS**：`weread menu.lua --smoke` → EXIT=0，渲染+恢复原屏，dmesg 无 segfault。整条管线（fb 备份→VM 启动→点阵字渲染→刷新→恢复）真机跑通。

### 关键发现 1：输入设备被 KOReader EVIOCGRAB 独占（架构级）

- 交互测试初次失败：按键无反应。写 `tools/evsniff.c` 诊断（用 EVIOCGRAB 抢占测试：抢到=无人独占，EBUSY=已被独占）。
- 确证：KOReader 运行时 `event0/event1` 均 `[GRABBED-by-other]`——KOReader 用 EVIOCGRAB 独占按键+五向键（屏蔽原生系统）。**即使 SIGSTOP 冻结 KOReader，grab 锁仍由其打开的 fd 持有**，其他读者收不到任何事件。`event2(volume)` free。
- **修复（生产必需）**：`wr_input_open` 对每个设备 EVIOCGRAB 独占、`wr_input_close` 释放。前台全屏应用必须独占输入，否则原生 cvm/KOReader 会同时读键并重绘盖屏（正是菜单被盖的同款机制）。实测：KOReader 退出后设备全 free，我方菜单启动即抢到（evsniff 反向确认 event0/1 = GRABBED-by-other=我们的菜单），退出后释放回 free（good citizenship，不锁死设备）。
- 原生框架 cvm **不**独占抓取——所以 KOReader 退出后我方 grab 能成功并排除原生。测试需先让 KOReader 释放（用户手动退出，进度自动保存）。

### 关键发现 2：show() 消息闪现（auto-repeat）

- 现象：中键选中后「press any key」消息一闪即回菜单。根因：按住中键时内核持续发 auto-repeat（value=2），show() 单次 `input_poll(-1)` 被同一按键的 repeat 立即满足。
- **修复**：`wr_input_poll` 加 `ignore_repeat` 参（跳过 value==2 只认首次按下 value==1）；Lua 侧 `input_poll(t, true)`。menu.lua show() 改为 `while wr.input_poll(-1, true) == nil do end`（循环等真实新按键），主循环也 ignore_repeat（离散按键、防长按重复触发 show/退出）。

### 验证

- 本地：`make host-selftest` HOST-OK；`make weread`/`make fbtest` 重建 exit=0 零警告（仅 dlopen-in-static 无害警告）。
- 真机：用户确认「正常响应」——高亮移动/中键选中/消息稳定不闪/退出正常；`menu done, sel=6` 干净退出；退出后 evsniff 确认 event0/1 回 `[free]`（grab 已释放）；dmesg 无 segfault。DK-1 step1 交互链全通验收闭环。

### 附带：GitHub/CI 可行性问答（用户提问）

结论=不划算且「公开」有风险：①交叉编译痛点已本地攻克，CI 无增量；②CI 够不到局域网 K4，真机在环验收（deploy/dmesg/目视）替代不了；③公开仓暴露多看固件逆向文档 + 微信读书非官方私有 API 客户端，法律/ToS 敏感。建议维持本地编译；若要可复现性走私有仓 + 自托管 runner，不公开。（未执行任何推送/建仓，等用户明确点头。）

### 下一步

DK-1 step2：freetype 中文渲染路线拍板（复用多看 libfreetype.so.6.5.0 动态变体 vs 上游静态自编）→ fb_draw_text 升级中文。其后 DK-2 网络层（首选复用多看 libcurl+OpenSSL 动态变体）。

## 2026-11-18 · DK-0 真机验收通过（K4 上线批次）

**目标**：解除 K4 离线阻塞，完成 DK-0 真机验收；顺带排查 SSH 认证与内存占用。

### 动作

1. 设备连通性排查：<K4_HOST> 不回 ICMP（ping 100% 丢包）但 ARP REACHABLE——WiFi 唤醒慢，SSH 需长 ConnectTimeout（30s 才握手成功；2s/10s 超时都是假阴性）。deploy 脚本未设 ConnectTimeout 时依赖 OpenSSH 默认超时，可用。
2. **SSH 认证修复**：设备 2222 = KOReader **魔改版 dropbear**（plugins/SSH.koplugin/main.lua:15-17），authorized_keys 从相对路径 `settings/SSH/authorized_keys` 读取（即 `/mnt/us/koreader/settings/SSH/authorized_keys`），非标准 `/tmp/root/.ssh/`。本机公钥装入该路径后免密登录生效；清理了误写入的 /tmp/root/.ssh（tmpfs，本就重启即消）。备份里发现旧 workbuddy 密钥（历史项目），未动。
3. **DK-0 真机验收 PASS**：`tools/deploy-k4.sh 5` → 量化自测 PASS；fb 实测 `600x800@8bpp line_length=600 smem_len=966656` 与方案 §4.1 假设一致；图案绘制+恢复刷新成功，EXIT=0；dmesg 无 segfault/fb 报错。屏幕视觉图案用户已目视确认，DK-0 验收完全闭环。
4. **内存占用分析**（KOReader 在场）：MemTotal 256MB / MemFree 13.9MB（假象），Buffers 33.6 + Cached 48.5 = 82MB 可回收，实际可用 ~96MB；AnonPages 108MB 中 cvm（Java 框架）58.1MB + reader.lua（KOReader）51.5MB 占 ~90%；无 swap，/mnt/us 是 vfat+FUSE 不便建 swapfile。结论：DK-0/1 内存充裕无需调优；开发期可选 `echo 3 > /proc/sys/vm/drop_caches`（零风险）或 `/etc/init.d/framework stop`（-58MB，可逆，本客户端走 raw fb ioctl 不依赖框架）；不建议上 swap。
5. Committed_AS 912MB / CommitLimit 128MB 说明：overcommit_memory=0 启发式模式不看 CommitLimit，912MB 是承诺预留量（Java arena/LuaJIT 地址空间）非实际占用，对几十 MB 级的本项目无影响。
6. HANDOFF 打钩：立即下一步第 1 条 → done；K4 离线 blocker → 解除。

### 下一步

DK-1：LuaJIT 2.1 armel 静态交叉编译（-joff）+ wrbridge.c FFI + menu.lua 按键菜单。

## 2026-11-16 · 铁律修订：多看资产复用解禁（标注制度）

**用户拍板**：多看系统刷机后与原系统并存；本系统走 KUAL 启动（并存不碰 rc5）；
**允许复用多看代码/资产，必须标注来源与版本；先把项目做起来，后续再优化。**

### 动作

1. README 铁律改写（复用+标注+先跑起来；KUAL 并存条目新增）。
2. 固件盘点 §四 资产判定翻转：固件 .so 从"不复用"改为"**可复用（标注）**"，落地形态记录两选：
   - 动态主进程变体 = **复刻多看自己的配方**（一手实证：KindleApp NEEDED 从原生系统取 libc/libm/libpthread/libgcc_s/libstdc++，从自带 lib/ 取其余 13 个；rundk.sh:386 `LD_LIBRARY_PATH=.:$SYS_LITE_PATH/lib/:../lib/` + FONTCONFIG_PATH）；前提=链接期用设备真实 /lib 作 sysroot（glibc 符号版本对齐，K4 在线后 pull 一条命令）。
   - 备选=上游源码静态自编（无 glibc 风险）。
   - 不可行形态明示：静态主进程 + dlopen 固件 .so（双 libc 堆/errno 分裂）。
3. TLS 结论简化（inventory §五 + 主抽取文档 §2.4）：**DK-2 首选复用多看 libcurl+OpenSSL（零编译）**，需动态变体；静态 OpenSSL 自编降为备选。DK-2 开工按设备在线状态拍板。
4. DK-1 保持：freetype 上游静态自编（设备离线约束下最快，避免动态变体的 glibc 对齐依赖）+ vendor 字体（授权字体现在可选配，随 NOTICE 标注）。
5. vendor/duokan/README 升级为复用制度文档：统一 NOTICE 声明模板（固件来源+版本+zip 哈希）+ 预留 lib/ 节。

### 影响面

- DK-1/DK-2 依赖表更新（主抽取文档 §五）；字体源、TLS 路线均已定版或留拍板点。
- "判死项"中 weread_ui patch/双缓冲等与复用解禁无关（那是"patch 闭源大件执行体"，非"复用其运行库"），维持判死。

## 2026-11-16 · 多看固件包原件盘点（用户澄清：原始文档=固件包本身）

**目标**：以固件原件（非评估报告）为一手来源，取证 K4 可用的底层资产。

### 动作

1. 校验 `/data/webdav/K4(xKindle_2015-05-15.36515.rtm).zip` SHA-256 与逆向报告一致；解包 1255 节点到 `/home/doro/duokan-fw-extract/`（仓库外工作区）。
2. **KindleApp 固件一手复核**（交叉 objdump，不经过报告转述）：设备路径 `/dev/fb0` + `/dev/input/event0/1/2`（strings）；fb 模块 0x494000–0x494d40 十处 ioctl；字面量池逐码计数 0x46db×1 / 0x46dd×1 / 0x4602×2 / 0x46f0 / 0x46f1 / 0x46e9 / 0x46ed，未用项 0x46e4/0x46ef/0x46e1/0x46f5 全 0——**逆向报告 §3 ioctl 清单经原件复验成立**。0x4600 计数为 0 的解释：ARM 立即数可编码（0x46 rot8），走 mov 不进池。
3. 运行时盘点：libfreetype.so.6.5.0（EABI4，NEEDED libz+libc）、libcurl.so.4.3.0（**curl 7.29.0 + OpenSSL 1.0.1e 内嵌**，解释包内无 libssl）、libdkkernel 10.9MB 等 13 库；字体 18 个（sysfonts 5 + userfonts 13）；rundk.sh GBK 转码实录启动链（S95framework 降级 + duokantag + LIPC）。
4. **资产判定**：固件 .so 不 dlopen（①铁律 ②EABI4 依赖宿主 libc + 静态 glibc 宿主 dlopen 坑 → 正确路径=上游源码静态编译）；**字体=数据资产可用**——开源可再分发子集（wqy-microhei.ttc GPLv2+FE、DejaVuSans.ttf）抽到 `vendor/duokan/fonts/`（vendor/ 已 gitignore），授权字体（方正/华文/微软系）留解包区本机用。
5. 产出 `docs/duokan-firmware-inventory.md`（一手盘点）+ 更新 `docs/duokan-k4-driver-architecture.md`（DK-1 字体源定版 + TLS 先例佐证改写：多看 OpenSSL 1.0.1e 2015 服役 = armel 生产先例，1.1.1 为保守降级档）。

### 注意

- 字面量池 grep 格式坑：NiLuJe binutils `objdump -s` 每字 8 hex 字符无空格（`db460000`），带空格 pattern 全零是假阴性。
- /tmp/ka_text.hex（19MB 中间物，临时）。

## 2026-11-16 · 多看逆向资产抽取（docs/）

**目标**：定位本机多看逆向原始文档，抽取 K4 实际可靠的底层驱动事实与可用架构，固化进项目。

### 动作

1. 定位证据源：多看逆向主报告（`~/reports/Duokan-xKindle-K4固件逆向与借鉴优化报告-2026-11-07.md`，REA/Ghidra 全量反汇编）+ 固件原件（`/data/webdav/K4(xKindle_2015-05-15.36515.rtm).zip`，SHA-256 可复核）+ isword 输入层/硬件门取证（`/home/doro/isword_k4/docs/phase3-input-layer.md`）+ K4Refresh 双机 A/B 报告与 ABI 代码。
2. 抽取并固化 → `docs/duokan-k4-driver-architecture.md`：
   - 底层驱动事实库（fb/eink ioctl 全量清单、fb 布局、量化恒等式、input evdev 三设备+uinput、工具链、LIPC 电源），逐条标注验证等级 L1双机/L2单机/L3反汇编/L4待验证；
   - 可用架构 7 条模式（单进程 fb 持有者、mmap 直绘+显式刷新、区域 partial 策略、排版分层、LIPC 门面、用户区部署、幂等量化）；
   - 判死项 5 条（weread_ui patch/双缓冲/现代 strace/内核波形/fast 档）；
   - DK-0~4 阶段对照表。
3. 发现并记录编号勘误：isword 文档的旋转 ioctl `0x4630` 与多看反汇编字面量池 `0x46f0/0x46f1` 不符，以反汇编为准（本项目不使用旋转，仅防误引）。
4. **补记网络栈风险**：自研进程内静态 OpenSSL3+curl 在 2.6.31/armv7 无真机先例（方案 §八未列）——DK-2 第一件事先做静态编译+K4 冒烟；备选 OpenSSL 1.1.1 或 K4Refresh musl 静态配方。

## 2026-11-15 · DK-0 二轮代码复核（离线）

**目标**：用户要求核实 bug 与回滚安全性。全量复核 fb.h/fb.c/main.c/Makefile/deploy-k4.sh。

### 复核结论

- 核对无误：update_area_t 24 字节 ABI（对齐 K4Refresh 真机验证版）；var/fix 手工镜像缓冲（284/304B）大于 2.6.31 内核 struct（内核只写自己的 sizeof）；量化 8 组向量逐位一致；fill_rect 边界钳制；量化只动可见区不碰驱动私有区。
- 发现并修复 3 项 + 1 项 errno：
  1. 🟠 失败路径/Ctrl+C 不恢复原屏 → main.c 重构：统一 `restore_screen()` + `goto out`，SIGINT/TERM 置位标志 + 分片 nanosleep 睡眠，任何退出路径先恢复再退出（中断退出码 130）。
  2. 🟠 恢复刷新返回值被忽略（失败仍打 fbtest OK）→ restore_screen 返回 rc 并检查。
  3. 🟡 deploy-k4.sh 的 DELAY 未校验直接拼远程命令 → 数字守卫（已用注入串实测拦截）。
  4. 🟢 bpp≠8 返回 -EBADF → -EINVAL。
  5. 顺手修：刷新失败与中断同时发生时 130 吞掉真实失败码 → 真实失败码优先。

### 验证

- `make host-selftest` PASS；`make fbtest` 零警告；qemu 冒烟 PASS（自测过/ENOENT 路径正确）。
- deploy 脚本 `bash -n` + 注入串守卫实测 PASS。

### 设备层回滚安全性（复核后结论）

正常路径 备份→画图→刷新→停留→恢复→刷新；失败/中断路径统一恢复。唯一残留情形：恢复刷新本身失败时面板停在图案，但 fb 内存已恢复，任意后续系统刷新（回 KOReader 按键等）即重绘原内容，无持久化残留。

## 2026-11-15 · DK-0 离线批次

**目标**：DK-0 工具链 + fb/eink 最小验证（技术方案 §五）。设备离线，本批次完成全部离线工作。

### 动作

1. 确认工具链 `~/x-tools/arm-kindle5-linux-gnueabi`（gcc 14.4.0）可用。
2. 参考 K4Refresh `src/eink.rs`（K4/K5 双机验证 ABI）+ `src/quant.rs`（Duokan nibble 量化）+ `src/fx.rs`（fx 档位语义），编写：
   - `src/device/fb.h/fb.c`：fb open/mmap + 0x4600/0x4602 信息 + 0x46db/0x46dd 刷新三件套 + fxquant + fill_rect + backup/restore + 量化自测。
   - `src/device/main.c`：DK-0 fbtest 入口（DK-1 起由 LuaJIT 主进程替换）。
   - `Makefile`：`make fbtest`（交叉静态）/ `make host-selftest`（主机量化自测）。
   - `tools/deploy-k4.sh`：部署 + 真机验证脚本。
3. 验证（离线可做的全部）：
   - `make host-selftest`：量化 8 组向量 + 幂等性 PASS。
   - `make fbtest`：产出 `build/fbtest` = ELF32 ARM EABI5 静态，GNU/Linux 2.6.31（与 K4 内核一致），-Wall -Wextra 无警告。
   - qemu-arm 冒烟：量化自测 PASS，fb open 路径正确返回 ENOENT（主机无 /dev/fb0），无非法指令。

### 阻塞

- **K4 真机验证 blocked**：<K4_HOST> ping 不通（ssh 2222 超时），设备当前离线。
  待设备上线后执行 `tools/deploy-k4.sh 5`，观察屏幕出现 白底+边框+16级渐变条+中央黑块，
  退出码 0，dmesg 无 segfault → DK-0 验收完成。

### 下一步

1. 设备上线 → `tools/deploy-k4.sh 5` → 完成 DK-0 验收。
2. DK-1：LuaJIT 2.1 交叉编译（-joff）+ wrbridge.c FFI 导出 + menu.lua 按键菜单。
