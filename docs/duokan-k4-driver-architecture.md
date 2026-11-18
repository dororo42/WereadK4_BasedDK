# 多看 K4 逆向资产抽取：K4 可靠底层驱动与可用架构

> 来源：多看（Duokan/xKindle）固件全量逆向 + isword_k4 取证 + K4Refresh 真机验证三方融合。
> 本文档是 WereadK4_BasedDK 的设备层依据库：每条事实标注验证等级与原文出处。
> 生成：2026-11-16（DK-0 批次）。

---

## 一、原始文档与证据源（本机路径）

| 证据源 | 路径 | 性质 |
|---|---|---|
| **多看固件逆向主报告** | `~/reports/Duokan-xKindle-K4固件逆向与借鉴优化报告-2026-11-07.md` | REA（Ghidra 12.1.3）全量反汇编定性，字面量池逐码读出 |
| 多看 K4 固件包原件 | `/data/webdav/K4(xKindle_2015-05-15.36515.rtm).zip` | 86.8MB，SHA-256 `07a223882ba55d7660a0a6bb6df94e48d6c645200b5ef47ac4d8b3a247245f60`（可复核） |
| KindleApp 主程序哈希 | 同上报告 §1 | SHA-256 `5021c8b8…09f8d8`，6,453,696B，ARM EABI4，stripped，armel |
| **isword 输入层取证** | `/home/doro/isword_k4/docs/phase3-input-layer.md` | K4 真机实测（evdev 清单 + uinput + 双缓冲钳制） |
| isword 硬件门取证 | `/home/doro/isword_k4/docs/phase2-device-gate.md` | 双缓冲代差判死的实证链 |
| **K4Refresh 对齐报告** | `~/reports/k4refresh-v0.1.10-Duokan对齐优化总结报告-2026-11-08.md` | 量化刷新 K4/K5 双机 A/B 实测 |
| K4Refresh ABI 代码 | `/home/doro/work/k4refresh/src/{eink,quant,fx}.rs` | 双机验证的 einkfb 封装（本仓 fb.c 的直接参照，**勿改动**） |
| weread API 形态表 | `~/reports/WereadK4_BasedDK-技术方案与实施计划-2026-11-15.md` §4.3 | weread_K4 插件（498 spec 绿）+ isword API 面取证 |

**验证等级标注**：`[L1]` K4/K5 双机实测；`[L2]` K4 单机实测；`[L3]` 反汇编定性（多看/KindleApp 字面量池或调用图）；`[L4]` 设计假设待真机验证。

---

## 二、K4 底层驱动事实库

### 2.1 fb / eink（本项目已按此实现）

**架构定性** `[L3]`：多看 KindleApp 是唯一持有 `/dev/fb0` 的 C++ 单进程，init 流程（0x494434）=
`open /dev/fb0 → FBIOGET_FSCREENINFO → mmap → SET_DISPLAY_ORIENTATION`，之后 blit 到 mmap 内存 + ioctl 刷新。
**单缓冲直接操作，无双缓冲、无 pan/swap**——K4 fb 硬件完全够用；isword 的双缓冲强制校验是它自己的设计选择（非硬件必需）。

**ioctl 全量清单** `[L3]`（KindleApp 11 个 ioctl 调用点，10 个在 fb 封装模块 0x494000–0x494d40）：

| 请求码 | 用途 | 多看是否使用 | 本项目 |
|---|---|---|---|
| 0x4600 | FBIOGET_VSCREENINFO | ✓ | ✓ fb.c |
| 0x4602 | FBIOGET_FSCREENINFO（init 两次探测） | ✓ | ✓ fb.c |
| **0x46db** | 整屏刷新，arg=fx_type 值 | ✓（fx∈{0,1}） | ✓ fb.c（备用，DK-1+ 用） |
| **0x46dd** | 区域刷新，arg=update_area_t*（24B ARM32） | ✓（翻页主路径） | ✓ fb.c |
| 0x46f0 / 0x46f1 | SET/GET_DISPLAY_ORIENTATION 旋转 | ✓（init 一次） | 暂不需要 |
| 0x46e9 / 0x46ed | SET/GET_REBOOT_BEHAVIOR | ✓ | 不需要 |
| 0x40044620 | FBIO_WAITFORVSYNC（fb.h 标准） | 未出现 | 用 `fsync(fd)` 等价替代 `[L3]`（FBInk/KOReader 同义） |
| 0x46e4 / 0x46ef / 0x46e1 / 0x46f5 | FX+排除矩形 / RESTORE / CLEAR / CONTRAST | **未使用** | 不需要 |

⚠️ **编号勘误**：isword 文档（phase3 再评估节）将旋转 ioctl 写作 `0x4630`，与多看反汇编字面量池读出的
`0x46f0/0x46f1` 不符——**以反汇编为准**（多看报告 §3）。0x4630 不属于 `_IO('F',n)` 的 einkfb 扩展段。
本项目不使用旋转，此项仅为防误引。

**fx 档位** `[L3→L1]`：多看只用了 partial(0)/full(1) 两档；fast(2)/slow(3) 全程未出现。
K4Refresh 补齐验证：fast 真机证伪搁置；slow 仅做收尾清残影（no-op 豁免，koreader#12774）。
**本项目刷新策略：区域 partial 为主 + 显式全刷（slow）收尾**——与多看一致且已被 K4Refresh 真机验证。

**update_area_t** `[L1]`（ARM32 24 字节，K4Refresh 真机验证 + 本仓 fb.h 同构）：
`{ int32 x1, y1, x2, y2; int32 which_fx; uint8* buffer; }`，x2/y2 为右/下开边界（传 x+w/y+h），buffer=NULL。

**fb 布局** `[L2]`（K4 实测）：600×800@8bpp 灰度，line_length=600，smem_len=966656，
**yres_virtual 钳制 800**——FBIOPUT 双缓冲扩展被驱动拒绝（fbvtest 实跑，isword 取证）。
可见区 480000 字节；smem_len 减可见区余量是驱动私有区，**不可触碰**（量化/绘制按行 stride=line_length、只动 x<xres 列）。

**16 级灰阶量化（多看渲染核心）** `[L3→L1]`：恒等式 `v' = (v & 0xF0) | (v >> 4)`（高 nibble 双写），
输出域 {17n | n∈0..15}，**幂等**。多看两处独立实现：0x1174a8（32bit→8bpp 转换尾段）、0x493e20（fb 转换路径逐字节）。
K4Refresh fxquant 双机 A/B：阶梯拟合 RMS −10~15%，partial 首轮快 ~20%（270→219ms）；
**量化不是鬼影消灭器，是漂移上界控制器**——单次大跳变的中段残留仍需全刷收尾。
`[L1]` 双机（K4/K5）交叉换位拍照，数值+肉眼互证。

**多看翻页刷新策略** `[L3]`（函数 0x494538 还原）：
`mode&2 → 0x46db 全刷闪（fx=1）+计数器`；否则区域 partial（fx=0）；
**角部启发式**：起点同时距右/下边缘 <50px → 升级为 0x46db 整屏 partial 不闪。
KOReader 侧复刻判定：完全可复刻（同一对 ioctl），无需内核/波形层。

### 2.2 input（evdev）

`[L2]`（K4 真机实测清单，isword 取证 2026-11-15）：

| 设备 | 名称 | 用途 |
|---|---|---|
| /dev/input/event0 | tequila-keypad | 按键（Menu/Home 等） |
| /dev/input/event1 | fiveway | 五向（上下左右中） |
| /dev/input/event2 | volume | 音量 ± |

- 内核 **2.6.31-rt11-lab126**，标准 evdev `struct input_event` 读取。
- **uinput 可用** `[L2]`：`modprobe uinput` 成功，模块 uinput.ko，节点 **`/dev/input/uinput`**（非 /dev/uinput）。
  本项目（路线 E）直接读 evdev，**不需要 uinput 注入桥**（那是 isword 触屏交互方案的桥，自研菜单无此依赖）。
- 多看/weread_ui 输入画像对照 `[L3]`：weread_ui 以触屏为主（无五向关键词），多看 KindleApp 的按键导航实现
  在二进制内未专项取证——**本项目按键 UI 全部自研**，KEY_* 码映射 `[L4]` 待 DK-1 真机实测补齐
  （event0/event1 逐键 dump，KOReader 设备层可作旁证）。

### 2.3 工具链

- `~/x-tools/arm-kindle5-linux-gnueabi`（NiLuJe crosstool-NG，gcc 14.4.0）`[L2]`：静态二进制 K4 实跑通过
  （isword 的 device-info/fb-dump/fbvtest + 本仓 fbtest qemu 级；多看 KindleApp 同为 armel）。
- 多看 KindleApp 为 **EABI4**（/lib/ld-linux.so.3 动态）；本仓产物为 EABI5 **静态**链接——
  不依赖 ld-linux，EABI5 静态在 K4 可跑已有先例 `[L2]`。
- 工程坑（多看报告 §8）：宿主 binutils 无 ARM 后端，交叉 objdump 用本工具链；多看脚本 GBK 编码需 iconv。

### 2.4 网络 / TLS

- weread API endpoint 形态 `[L2]`：weread_K4 插件双机在用（登录/续期/书架/章节/进度/上报），见方案 §4.3 表。
- **TLS 栈 `[L4]`**：**首选复用多看 libcurl.so.4**（curl 7.29.0 + OpenSSL 1.0.1e 内嵌，零编译，K4 十年服役先例）
  ——需动态主进程变体（复刻多看 LD_LIBRARY_PATH 模式，链接期用设备真实 /lib 作 sysroot）。
  备选：OpenSSL 3.x 静态自编（坑则降 1.1.1）。两条路线 DK-2 开工拍板，
  判据与配方见 `docs/duokan-firmware-inventory.md` §四/§五。

### 2.5 电源 / 系统底座

- **LIPC 是与 Kindle 底座交互的唯一标准通道** `[L3]`：多看全程只用 `lipc-set-prop` / `lipc-wait-event`、
  `kdb`、`/proc/usid` 设备识别——零内核改动、零 .ko。
- 电源伴生模式 `[L3]`：多看 PowerState.bin = `lipc-wait-event` 监听 + `killall -56 KindleApp`（信号级退出）。
  本项目 DK-3（待机/唤醒/自动休眠）按同款 LIPC 模式实现。
- 多看无波形文件、无内核通道 `[L3]`：包内零 .ko / 零 uImage / 零 waveform 文件，DK_System 全住 /mnt/us USB 可见区。

---

## 三、可用架构模式（多看已证 → 本项目映射）

| # | 多看模式（反汇编定性） | 本项目映射 | 状态 |
|---|---|---|---|
| 1 | **单进程单 fb 持有者**：UI/排版/刷新策略/网络全在一个 C++ 进程 | 单进程：C 设备层 + LuaJIT 嵌入业务（比 C++ monolith 多一层脚本隔离） | DK-0 fb 层已建，DK-1 进程骨架 |
| 2 | **mmap 直绘 + 显式 ioctl 刷新**（绘制与刷新分离，量化在绘制/转换时刻） | fb.c 同构：fill/quant 分离，refresh 显式调用；量化幂等允许绘制期反复执行 | ✓ 已实现 |
| 3 | **区域 partial 为主 + 显式全刷收尾**（翻页=区域 partial；角部小区域升级整屏不闪） | 菜单/阅读翻页走 0x46dd partial；N 页/退出时 slow 全刷 | DK-1 策略层实现 |
| 4 | **排版引擎分层**：libdkkernel.so（排版）与 freetype（栅格化）分离，CJK 排版是多看阅读体验的核心 | DK-1 先 freetype 直绘简版；排版引擎独立迭代（crengine 简版起步，方案 §八） | 最大工程项，方案已列风险 |
| 5 | **LIPC 门面**：与底座只走标准 LIPC，不碰内核 | DK-3 电源管理同款 | 设计输入 |
| 6 | **用户区部署 + rc5 双系统共存**（S95/S96 接管、降级/恢复原生 framework） | 本项目改走 KUAL（不碰 rc5，风险更低；KUAL_Booklet 资产已有） | DK-4 |
| 7 | **16 级量化 + 幂等**贯穿所有绘制路径 | fb.c wr_fb_quant 同款；KOReader/K4Refresh 已真机验证 | ✓ 已实现 |

## 四、判死项（不可行，勿重蹈）

| 项 | 判死证据 | 等级 |
|---|---|---|
| patch weread_ui / isword 二进制适配 K4 | 闭源 stripped + 双缓冲强制校验（「可用页数不足(1)」）+ FBIOPUT 双缓冲被驱动钳制 + strace 三连败（2.6.31 无 PTRACE_GETREGSET），SIGSEGV 实证 | `[L2]` |
| 双缓冲渲染（FBIOPAN_DISPLAY/pan/swap） | K4 fb 驱动 yres_virtual 钳制 800，双缓冲扩展被拒（fbvtest 实测） | `[L2]` |
| 现代取证工具（strace ≥4.26/gdbserver） | static-pie 与 no-pie 均 SIGSEGV，2.6.31 缺现代 ptrace 接口 | `[L2]` |
| 内核/波形层优化 | 多看自己都没用（零 .ko/零波形）；KOReader 侧完全可复刻结论 | `[L3]` |
| fx=fast(2) 档押注 | K4Refresh 真机证伪（与多看未用该档互证） | `[L1]` |

## 五、本项目落地状态对照

| 方案阶段 | 依赖的驱动/架构事实 | 状态 |
|---|---|---|
| DK-0 fb/eink | §2.1 全部 + §2.3 工具链 | 代码完成，真机验收 blocked（K4 离线） |
| DK-1 LuaJIT+菜单 | §2.2 input（KEY 码待实测）+ 模式 1/3 + **字体已定版**：vendor/duokan/fonts（wqy-microhei CJK 主 + DejaVu Latin；授权字体可选配，随 NOTICE 标注）+ freetype 上游静态自编（设备离线约束下最快；复用固件 libfreetype 需动态变体，归入 DK-2 拍板点） | 待 DK-0 验收后开工 |
| DK-2 业务 | §2.4 API（已验证形态）+ **TLS：首选复用多看 libcurl+OpenSSL（动态主进程变体，需 pull 设备 /lib 作 sysroot）；备选静态 OpenSSL 自编**，开工拍板 | — |
| DK-3 稳定性 | §2.5 LIPC 电源 + MemFree 基线 | — |
| DK-4 集成 | 模式 6 → KUAL 替代 rc5 路线 | — |
