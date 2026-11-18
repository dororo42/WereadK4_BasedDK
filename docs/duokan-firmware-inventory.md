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

## 四、对本项目的资产判定（结合铁律）

| 资产类 | 判定 | 依据 |
|---|---|---|
| KindleApp/libdkkernel/libkss 二进制 | ❌ 不复用 | 项目铁律 + 闭源 stripped |
| 固件内 .so（freetype/curl 等） | ❌ 不 dlopen | ① 铁律（多看编译成品）；② EABI4 .so 依赖宿主 libc，EABI5 静态 glibc 宿主 dlopen 有静态 TLS/加载器坑；③ **正确路径 = 上游开源源码静态编译**（freetype → DK-1，curl+OpenSSL3 → DK-2），多看 .so 仅作版本与可行性参照 |
| **字体文件（数据，非代码）** | ✅ 可用 | 开源字体已入 vendor/duokan/fonts；授权字体留解包区供本机配置 |
| 启动链/LIPC 脚本模式 | ✅ 借鉴 | rundk.sh 一手实录如上 |
| dk2system.bin 切换屏原图 | 参考 | 600×800 4bpp/8bpp 双形态，佐证量化 16 级设计 |

## 五、TLS 栈可行性佐证（更新 §2.4 风险注记）

多看在 K4 上跑 TLS 的先例 = **OpenSSL 1.0.1e（2013）静态内嵌 libcurl**，2015 固件服役至今——
armel/armv7 + 2.6.31 上 OpenSSL 生产可用有长期实证。本项目 DK-2 计划 OpenSSL 3.x 静态编译：
先例支持"可行"，但 3.x 对内核版本无硬要求、对 glibc 符号有要求（静态编译自带 libc 则无碍），
仍按原计划 DK-2 开工先冒烟；若 3.x 交叉静态有坑，1.1.1 是已被多看验证的保守档（1.0.1e 已 EOL 不选）。
