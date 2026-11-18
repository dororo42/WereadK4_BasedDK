# WereadK4_BasedDK — 交叉编译（arm-kindle5-linux-gnueabi，静态链接）
# DK-0 目标：build/fbtest

CROSS ?= $(HOME)/x-tools/arm-kindle5-linux-gnueabi/bin/arm-kindle5-linux-gnueabi-
CC := $(CROSS)gcc

CFLAGS := -std=gnu99 -Wall -Wextra -O2 -static
LDFLAGS := -static

BUILD := build

.PHONY: all clean fbtest weread host-selftest

all: fbtest weread

fbtest: $(BUILD)/fbtest

$(BUILD)/fbtest: src/device/fb.c src/device/main.c src/device/fb.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ src/device/fb.c src/device/main.c $(LDFLAGS)

# ---- DK-1: LuaJIT 主进程 ----
LUAJIT_DIR := vendor/luajit
LUAJIT_A   := $(LUAJIT_DIR)/src/libluajit.a
LUAJIT_INC := $(LUAJIT_DIR)/src

# ---- DK-1 step2: freetype 静态自编（上游 2.13.2，FreeType License，NOTICE 标注）----
# 构建：cd vendor/freetype && CC=<cross-gcc> ./configure --host=arm-kindle5-linux-gnueabi \
#         --disable-shared --enable-static --without-zlib --without-bzip2 --without-png \
#         --without-harfbuzz --without-brotli && make
FT_DIR := vendor/freetype
FT_A   := $(FT_DIR)/objs/.libs/libfreetype.a
FT_INC := $(FT_DIR)/include

# LuaJIT 2.1 armel 静态库（禁 JIT）。一次性构建：host 工具需 32 位（gcc -m32，
# 否则 buildvm 指针尺寸与 ARM32 target 不匹配）。已存在则跳过。
$(LUAJIT_A):
	$(MAKE) -C $(LUAJIT_DIR) HOST_CC="gcc -m32" CROSS=$(CROSS) \
	  TARGET_SYS=Linux BUILDMODE=static XCFLAGS=-DLUAJIT_DISABLE_JIT \
	  TARGET_LDFLAGS=-static

WEREAD_SRCS := src/device/fb.c src/device/input.c src/device/render.c src/bridge/wrbridge.c src/host/wrmain.c
WEREAD_INC  := -Isrc/device -Isrc/bridge -I$(LUAJIT_INC) -I$(FT_INC)
WEREAD_HDRS := src/device/fb.h src/device/input.h src/device/font8x16.h src/device/render.h src/bridge/wrbridge.h

weread: $(BUILD)/weread

$(BUILD)/weread: $(WEREAD_SRCS) $(WEREAD_HDRS) $(LUAJIT_A) $(FT_A)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(WEREAD_INC) -o $@ $(WEREAD_SRCS) \
	  -Wl,--start-group $(LUAJIT_A) $(FT_A) -lm -ldl -lrt -Wl,--end-group $(LDFLAGS)

# 主机侧快速语法检查（主机 gcc，跑量化自测；fbtest 目标才用交叉工具链）
host-selftest:
	@mkdir -p $(BUILD)
	gcc -Isrc/device -o $(BUILD)/quant_test -DWR_QUANT_TEST_MAIN src/device/fb.c && $(BUILD)/quant_test && echo HOST-OK

clean:
	rm -rf $(BUILD)
