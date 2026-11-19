# K4 键位约定（对齐 KOReader + weread_K4 习惯）

> 用户要求：保留 weread_K4 插件下的快捷键使用习惯。
> 结论先行：**插件的键位不是它自己定的**，而是 KOReader 在 K4 上的默认键位——插件只劫持了四处
> （`ScreenKB+Down`、`Home`、`Menu`、`Back`，见 `weread_K4.koplugin/weread/ui/reader_navigation.lua:18-161`）。
> 所以「保留习惯」= 对齐 KOReader 键位表，出处 `weread_K4.koplugin/README.md:70-88`。
> 本仓已按该表实现，**两处刻意偏离**见 §三。

---

## 一、K4 物理键与 evdev 码

物理键只有：5 向 D-pad、左右翻页键（各 2 个）、Home / Back / Menu / Keyboard(ScreenKB)。
码→键名映射取自 KOReader `event_map_kindle4.lua`（FW 3.x/4.x 设备实测），落在
`src/device/input.c` 的 `kMap`：

| evdev code | 键名 | 设备节点 |
|---|---|---|
| 28 / 194 | `Press`（D-pad 中键，两个码同义） | event1 fiveway |
| 103 / 108 / 105 / 106 | `Up` / `Down` / `Left` / `Right` | event1 fiveway |
| 102 / 139 / 158 | `Home` / `Menu` / `Back` | event0 tequila-keypad |
| 104 / 191 | `LPgFwd` / `RPgFwd`（下一页） | event0 tequila-keypad |
| 109 / 193 | `RPgBack` / `LPgBack`（上一页） | event0 tequila-keypad |
| 29 | `ScreenKB`（**修饰键**，见 §四） | event0 tequila-keypad |

## 二、阅读态键位（`src/lua/reader.lua` 的 `Reader.KEY_*` 表）

| 键 | 本项目动作 | KOReader 原义（插件 README 行号） |
|---|---|---|
| `LPgFwd` / `RPgFwd` | 下一页；末页再往前 → **下一章**（自动续读） | 下一页（:76） |
| `LPgBack` / `RPgBack` | 上一页；首页再往后 → **上一章末页** | 上一页（:77） |
| `Right` | 下一章 | 下一章（:74） |
| `Left` | 上一章 | 上一章（:74） |
| `Up` / `Down` | 上一页 / 下一页 | 内容选择模式（:75）——**偏离 1** |
| `Press` | 下一页 | 底部菜单（:81）——**偏离 2** |
| `Menu` | 快捷菜单（目录 / 退出阅读） | 顶部菜单（:80） |
| `ScreenKB+Down` | 快捷菜单（同上） | 微信读书快捷菜单（:84） |
| `ScreenKB+Up` | 目录（章节列表跳转） | 目录（:82） |
| `Back` | 保存进度 → 退出到菜单 | 返回/关闭（:78） |
| `Home` | 保存进度 → 退出到菜单 | weread-only 模式 = 书架（:79） |
| 其它键 | 静默忽略 | — |

跨章动作不在 reader 内决策：reader 只返回 `action ∈ next_chapter | prev_chapter | toc | exit`，
`menu.lua:read_book` 是**唯一**的跨章决策点（它持有目录与进度）。

菜单/书架态键位无需对齐改动，本来就与 KOReader Menu widget 一致：
`Up/Down` 移动、`Left/Right` 翻屏、`Press` 选择、`Back` 返回（`menu.lua`、`shelf.lua`）。

## 三、两处刻意偏离（可一行翻转）

1. **`Up`/`Down` = 翻页**（KOReader 是「内容选择」查词/高亮模式）。
   理由：本项目没有选词功能，这两个键在阅读态否则完全空闲；降级为翻页不与任何既有语义冲突，
   且 `ScreenKB+Up/Down` 的组合语义仍然保留（C 层 latch 优先，不会误翻页）。
   将来做选词/高亮时，把这两项从 `Reader.KEY_NEXT_PAGE`/`KEY_PREV_PAGE` 移走即可。
2. **`Press` = 下一页**（KOReader 是底部菜单）。
   理由：D-pad 中键是最高频的翻页位，而「底部菜单」的能力已由 `Menu` 与 `ScreenKB+Down`
   两个键完整覆盖，不缺入口。
   翻转成本：把 `Press` 从 `Reader.KEY_NEXT_PAGE` 移到 `Reader.KEY_TOC`（一行），
   `tests/reader_keys_test.lua` 会强制同步更新断言。

## 四、ScreenKB 组合键的实现（C 层 latch）

KOReader 的组合键事件名形如 `ScreenKBPlusDown`（由内置 hotkeys.koplugin 消费，
`reader_navigation.lua:22-26` 引 KOReader v2026.07 源码实证）。本仓在 **C 输入层**复刻同一语义：

- `src/device/input.c`：`wr_input_poll` 内部 latch `code 29` 的 press/release，
  修饰键自身**不产出事件**（同 KOReader）；其它键经 `wr_key_combo()` 拼出 `ScreenKBPlus<Key>`。
- latch 挂在 `struct wr_input`（**必须跨设备**：code 29 在 event0，D-pad 在 event1）。
- latch 处理排在通用 release 过滤**之前**，否则抬起事件被丢弃 → 修饰键粘住。
- evdev 队列 FIFO + 内层排空读取 → 提前 return 只是把余下事件留到下次 poll，顺序不乱。
- 组合名写入 `struct wr_input.combo[24]`，**仅在下次 poll 前有效**；Lua 桥
  `lua_pushstring` 立即拷贝，无生命周期风险。

latch 是**通用**的（任意 `ScreenKBPlus<Key>` 都能产出），但绑定随功能落地——目前只绑了
`Up`/`Down` 两个。插件其余组合键待对应功能实现后再接：

| 组合键 | 插件语义（README） | 本项目状态 |
|---|---|---|
| `ScreenKB+Right` | 添加书签（:83） | 未实现（无书签功能） |
| `ScreenKB+Left` | 书签/笔记/高亮列表（:85） | 未实现 |
| `ScreenKB+Press` | 保存当前页到位置历史（:86） | 未实现 |
| `ScreenKB+Home` | 开关 Wi-Fi（:87） | 未实现（DK-4 KUAL/系统面） |
| `ScreenKB+Back` | 切换到上一本书（:88） | 未实现 |

## 五、验证

- 离线（现在可跑）：`make host-selftest` → C 侧组合名拼装自测（`WR_INPUT_TEST_MAIN`）；
  `make host-lua-test` → `tests/reader_keys_test.lua` 钉住整张键位表
  （翻页键/换章键/目录键/退出键、一键一义、键名拼写护栏、修饰键自身不绑动作）。
- 真机（设备上线后）：`tools/deploy-weread.sh --interactive` →
  书架选书 → `RPgFwd` 翻页 → 章末自动进下一章 → `ScreenKB+Up` 目录跳转 → `Back` 退出 →
  「继续阅读」回到同章同页 → `Left/Right` 换章 → `Menu` 快捷菜单。
  **唯一无法离线验证的假设**：真机 evdev 上 code 29 的 press/release 是否成对出现
  （若只报 press 不报 release，修饰键会粘住 → 需要在 C 层加超时自动释放）。

## 出处

- `/home/doro/weread_K4.koplugin/README.md:63-88`（K4 键盘操作速查表，KOReader + hotkeys.koplugin + 该分支改动）
- `/home/doro/weread_K4.koplugin/weread/ui/reader_navigation.lua:18-161`（插件劫持的四处键位及其 KOReader 源码行号引用）
- KOReader `event_map_kindle4.lua`（码→键名，转引自插件文档与 `src/device/input.h` 注释）
