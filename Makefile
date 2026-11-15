# WereadK4_BasedDK — 交叉编译（arm-kindle5-linux-gnueabi，静态链接）
# DK-0 目标：build/fbtest

CROSS ?= $(HOME)/x-tools/arm-kindle5-linux-gnueabi/bin/arm-kindle5-linux-gnueabi-
CC := $(CROSS)gcc

CFLAGS := -std=gnu99 -Wall -Wextra -O2 -static
LDFLAGS := -static

BUILD := build

.PHONY: all clean fbtest host-selftest

all: fbtest

fbtest: $(BUILD)/fbtest

$(BUILD)/fbtest: src/device/fb.c src/device/main.c src/device/fb.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -o $@ src/device/fb.c src/device/main.c $(LDFLAGS)

# 主机侧快速语法检查（主机 gcc，跑量化自测；fbtest 目标才用交叉工具链）
host-selftest:
	@mkdir -p $(BUILD)
	gcc -Isrc/device -o $(BUILD)/quant_test -DWR_QUANT_TEST_MAIN src/device/fb.c && $(BUILD)/quant_test && echo HOST-OK

clean:
	rm -rf $(BUILD)
