# 多看 K4 固件包原件盘点（固件一手取证）

> 对象：`/data/webdav/K4(xKindle_2015-05-15.36515.rtm).zip`，86.8MB，
> SHA-256 `07a223882ba55d7660a0a6bb6df94e48d6c645200b5ef47ac4d8b3a247245f60`（与逆向报告 §1 一致）。
> 解包：1255 节点 → `/home/doro/duokan-fw-extract/K4(xKindle_2015-05-15.36515.rtm)/`（1178 文件，208MB）。
> 本文档为「原始文档 = 固件包本身」的一手取证记录；上游深度反汇编结论见
> `docs/duokan-k4-driver-architecture.md`。生成：2026-11-16。

---

## 一、包结构（一手实测）

```
K4(xKindle_2015-05-15.36515.rtm)/
├── DK_System/
│   ├── bin/     dk2system.bin(4bit/8bit 切换屏原图)、rundk.sh(GBK)、WaiteAKey(ELF)、update.sh
│   ├── install/ DK_run / DK_switch / DuoKanInstall.sh（诊断模式安装）+ K4_4.0.0/4.1.0 旧版目录
│   └── xKindle/ 198MB 运行时（下详）
└── （zip 顶层另有两个旧版安装目录，非运行时）
```

## 二、KindleApp 直接复核（固件一手，不经过报告转述）

| 项 | 实测值 | 方法 |
|---|---|---|
| ELF 身份 | ARM EABI4，动态，interpreter `/lib/ld-linux.so.3`，GNU/Linux **2.6.14** floor，stripped，C++ | readelf -h |
| 设备路径 | **`/dev/fb0`、`/dev/input/event0`、`/dev/input/event1`、`/dev/input/event2`** | strings 实证 |
| fb 模块 | 0x494000–0x494d40，10 处 `bl ioctl@plt` 密集调用 | 交叉 objdump -d |
| ioctl 字面量池 | **0x46db×1、0x46dd×1、0x4602×2、0x46f0×1、0x46f1×1、0x46e9×1、0x46ed×1** | objdump -s -j .text 字节序读数 |
| 未出现（字面量池 0 处） | 0x46e4 / 0x46ef / 0x46e1 / 0x46f5 | 同上 |
| 0x4600 的 0 计数解释 | 0x4600 可编为 ARM 立即数（0x46 rot 8），走 `mov` 不进字面量池；0x4602 12 位有效需池化 → **×2 与报告"init 两次探测"吻合** | 编码推演 + 实测 |

⇒ 逆向报告 §3 的 ioctl 全量清单**经固件原件逐码复验成立**；本仓 `fb.h` 的 ABI 常量与固件一致。

## 三、运行时资产（DK_System/xKindle）

### 3.1 代码/库（铁律：不复用多看二进制，仅记录）

| 文件 | 大小 | 身份 | 说明 |
|---|---|---|---|
| KindleApp | 6.4MB | EABI4 C++ stripped | 主程序，fb 唯一持有者 |
| libdkkernel.so | 10.9MB | stripped C++ | 排版引擎（架构借鉴对象） |
| libkss.so | 1.2MB | DRM SDK | 无关 |
| libfreetype.so.6.5.0 | 747KB | soname libfreetype.so.6，NEEDED libz+libc | ≈FreeType 2.5.0 |
| libcurl.so.4.3.0 | 1.9MB | NEEDED librt/libgcc_s/libc | **curl 7.29.0 + OpenSSL 1.0.1e 内嵌**（strings 实证） |
| libxml2.so.2.7.4 / libz.so.1.2.5 / libiconv / libcharset / libjson-c / libzip / libunrar / libcares / libasound | — | — | 辅助库 |
| python2.6 / alsa(libasound) / web_browser(Qt4) / miniftpd | — | — | 辅助设施，本项目不用 |

### 3.2 启动链（rundk.sh GBK 转码一手实录）

`stitch_to_ebook/lite/kindle` 三模式切换：`lipc-set-prop com.lab126.audio Kill 1` →
`mntroot rw` → 恢复 s96rundk→S96rundk → **`mv S95framework → s95framework`（降级原生框架）** →
写 `/mnt/us/DK_System/Lite/duokantag` → `mntroot ro` → `S96rundk`。
WaiteAKey（唯一未 strip 且带 debug_info 的 ELF）：按键等待器。
⇒ 多看与原生双系统共存的实现全部在 rc5 文件名交换 + tag 文件 + LIPC，零内核改动。
本项目 DK-4 走 KUAL，不碰 rc5（更安全），此链作为模式参照。

### 3.3 字体（res/sysfonts 5 + res/userfonts 13）

**开源可再分发（已抽到 vendor/duokan/fonts/，哈希见 vendor README）**：
- `wqy-microhei.ttc` 5.2MB（GPLv2+嵌入例外）→ **DK-1 CJK 主字体首选**
- `DejaVuSans.ttf` 720KB（DejaVu）→ Latin 回退
- 解包区另有 `DejaVuSerif.ttf`、`GenBkBas.ttc`（源真黑体系，OFL）、`Inconsolata.ttf`（OFL）

**授权字体（本机使用无碍，不入 vendor 不分发）**：
- 方正系：fzlth_gb18030 / fzltkh_gbk / fzssjt / fzxbsjt（多看阅读体验的核心字体）
- 华文/汉仪系：hwkt.ttf 13MB、hyfs.ttf 13MB
- 微软系：Arial / verdana / GOTHIC / trebuc / Comic
- 多看自制：dk-symbol.ttf（符号）、lingoes.ttf

## 四、对本项目的资产判定（2026-11-16 铁律修订：复用允许+标注）

> 用户修订铁律：**允许复用多看代码/资产，必须标注来源与版本；先把项目做起来，后续再优化。**
> 复用与自研的边界不再是"能否复用"，而是"哪条路径最快可用、标注是否到位"。

| 资产类 | 判定 | 复用路径与标注 |
|---|---|---|
| KindleApp/libdkkernel/libkss 二进制本体 | ❌ 仍不复用执行 | 闭源 stripped 大件，无复用价值；仅作架构/接口取证 |
| **固件内 .so（freetype/curl/z 等）** | ✅ **可复用（标注）** | 两种落地形态：① **动态主进程变体**——复刻多看自己的模式（interpreter `/lib/ld-linux.so.3` 取原生 libc/libm/libstdc++ + `LD_LIBRARY_PATH` 挂自带 lib 副本，rundk.sh:386 一手实证）；前提=链接期用设备真实 libc 作 sysroot（glibc 符号版本对齐，K4 在线后 `ssh` pull `/lib` 一条命令）；② 备选=上游源码自编译静态（无 glibc 风险）。**静态主进程 + dlopen 固件 .so 不可行**（双 libc 堆/errno 分裂）。标注=来源 DK_System/xKindle 版本 36515.rtm + 各文件 SHA-256 |
| **字体（数据）** | ✅ 已复用 | 开源子集已入 `vendor/duokan/fonts/`（标注哈希+授权）；**授权字体（方正/华文/微软系）本机可用**，部署到设备随 NOTICE 标注 |
| 启动链/LIPC 脚本模式 | ✅ 借鉴+标注 | rundk.sh 一手实录；我们走 KUAL 不碰 rc5 |
| dk2system.bin 切换屏原图 | 参考 | 佐证 16 级量化设计 |

**多看自己的动态复用配方（KindleApp NEEDED 一手实证，可直接照抄）**：
- 取自原生系统：libc.so.6 / libm.so.6 / libpthread.so.0 / libgcc_s.so.1 / libstdc++.so.6
- 取自带包 lib/（13 个）：libasound/libz/libfreetype/libxml2/libiconv/libcurl/libzip/libunrar/libcares/libdkkernel/libjson-c/libkss
- 运行时：`LD_LIBRARY_PATH=.:$SYS_LITE_PATH/lib/:../lib/` + `FONTCONFIG_PATH`（rundk.sh:385-389）

## 五、TLS 栈（2026-11-16 铁律修订后简化）

复用多看 `libcurl.so.4.3.0`（curl 7.29.0 + OpenSSL 1.0.1e 内嵌）= **零编译获得 TLS**，
条件是走动态主进程变体（§四①）。此前"OpenSSL 3.x 静态编译冒烟"降为备选路线
（若坚持全静态宿主）。两条路线 DK-2 开工时按设备在线状态拍板：
- 设备在线（可 pull /lib sysroot）→ 动态变体 + 复用 libcurl（先做起来，最快）
- 全静态坚持 → OpenSSL 3.x 自编冒烟，坑则降 1.1.1（多看 1.0.1e 2015 服役 = armel 长期先例）
