/* render.h — freetype 文字渲染层（8bpp fb 直绘，UTF-8 输入）。
 *
 * DK-1 step2：中文渲染。字体文件为数据资产（vendor/duokan/fonts，多看固件抽取，
 * 见 vendor/duokan/README.md 标注）；freetype 为上游源码静态自编（vendor/freetype，
 * FreeType License，NOTICE 标注）。
 */
#ifndef WR_RENDER_H
#define WR_RENDER_H

#include "fb.h"

#define WR_FT_MAX_FONTS 8

int  wr_ft_init(void);                                   /* 幂等 */
void wr_ft_done(void);

/* 加载字体（TTF/TTC，face index 0），px_size 为像素字号。返回 font id（>=0），失败返回负 errno。 */
int  wr_ft_load(const char *path, int px_size);
void wr_ft_unload(int id);

/* 绘制一行 UTF-8 文本（背景透明，fg=文字灰度 0 黑~255 白）。y 为行顶。
 * 返回结束 x 坐标；失败返回负 errno。 */
int  wr_ft_draw(struct wr_fb *fb, int id, int x, int y, const char *utf8, uint8_t fg);

/* 一行宽度（px，逐字 advance 之和）。失败返回负 errno。 */
int  wr_ft_width(int id, const char *utf8);

#endif
