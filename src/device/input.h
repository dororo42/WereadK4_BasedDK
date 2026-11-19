/* input.h — K4 evdev 输入层（五向键 + 面板按键）。
 *
 * 设备节点（isword_k4 设备实测 + KOReader device.lua:568-569 同款）：
 *   /dev/input/event0 = tequila-keypad（Home/Back/Menu/翻页键）
 *   /dev/input/event1 = fiveway（Up/Down/Left/Right/Press 中键）
 *   /dev/input/event2 = volume（本项目不用）
 *
 * 键码 = Linux evdev 标准码，映射取自 KOReader event_map_kindle4.lua
 * （FW 3.x/4.x 设备实测，权威来源）。struct input_event 手工镜像为 16 字节，
 * 避开工具链 glibc time_t 尺寸歧义（内核 2.6.31 ARM32 ABI）。
 */
#ifndef WR_INPUT_H
#define WR_INPUT_H

#include <stdint.h>
#include <stddef.h>

#define WR_IN_MAXDEV 2

/* EV_KEY 事件 value 语义 */
#define WR_KEY_RELEASE 0
#define WR_KEY_PRESS   1
#define WR_KEY_REPEAT  2

/* 修饰键（K4 面板 Keyboard 键，evdev code 29）。KOReader 里它是组合键前缀
 * （ScreenKB+Up=目录 等，见 weread_K4 README.md:82-88），自身不产出事件。 */
#define WR_KEY_MOD_CODE 29
/* 组合名缓冲："ScreenKBPlus" (12) + 最长基名 "ScreenKB"(8) + NUL */
#define WR_IN_COMBO_LEN 24

struct wr_input {
    int fds[WR_IN_MAXDEV];
    int grabbed[WR_IN_MAXDEV];  /* 对应 fd 是否已被本进程 EVIOCGRAB 独占 */
    int ndev;
    /* 修饰键 latch：必须跨设备——ScreenKB 来自 event0(tequila-keypad)，
     * D-pad 来自 event1(fiveway)，两者不在同一 fd 上。 */
    int mod_held;
    long mod_press_ms;            /* 修饰键按下时刻（CLOCK_MONOTONIC ms），latch 超时释放用 */
    char combo[WR_IN_COMBO_LEN];  /* wr_key_combo 的拼装缓冲，下次 poll 前有效 */
};

/* evdev code -> 逻辑键名（与 KOReader event_map_kindle4 对齐）；未知返回 NULL。 */
const char *wr_key_name(uint16_t code);

/* code -> 键名，mod_held!=0 时产出组合名 "ScreenKBPlus<Key>"（写入 buf 并返回 buf；
 * 事件名对齐 KOReader hotkeys.koplugin 的 ScreenKBPlusDown）。无修饰时直接返回
 * wr_key_name 的静态串，不碰 buf。未知 code 返回 NULL。 */
const char *wr_key_combo(uint16_t code, int mod_held, char *buf, size_t buflen);

int  wr_input_open(struct wr_input *in);
void wr_input_close(struct wr_input *in);

/* 轮询按键：timeout_ms<0 阻塞，=0 立即返回，>0 超时毫秒。
 * ignore_repeat!=0 时跳过 auto-repeat（value==2），只认首次按下（value==1）——
 * 菜单类交互用，避免长按重复触发。返回 1 且有键（*name 置键名），0 超时/无合格键，-1 错误。 */
int  wr_input_poll(struct wr_input *in, int timeout_ms, const char **name,
                   int ignore_repeat);

#endif
