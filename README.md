# miniRV (HDL + Verilog + C, Mac-friendly)

本工程实现 miniRV，并补了图形显示（VGA 显存映射）验证流程。

## 已实现内容

- `rtl/minirv.v`: miniRV 核心（8 条指令）
  - `add/addi/lui/lw/lbu/sw/sb/jalr`
- `tb/minirv_tb.v`: RAM + VGA MMIO 的 testbench
  - VGA 显存区：`0x20000000 ~ 0x2003ffff`
  - 支持 `+FBDUMP=...` 导出帧缓冲
- C 工具
  - `tools/logisim_hex_to_words.c`: 把官方 `v3.0 hex words addressed` 转成 Icarus 可读格式
  - `tools/check_output.c`: 检查 `FINAL pc/a0`，可附带图像像素检查
  - `tools/fb_to_ppm.c`: 将 VGA 写事件还原成 `PPM`
  - `tools/gen_tests.c`: 生成基础自测程序

## “两个 tb 结果”代表什么

这里的“两个结果”指基础回归测试：

- `run-basic-mem`
  - 主要覆盖 `lbu/sb/lw/sw/add/addi/lui/jalr` 的组合路径
  - 期望 `pc=0x20, a0=0x12`
- `run-basic-sum`
  - 主要覆盖算术与控制流稳定性
  - 期望 `pc=0x44, a0=0x7a314 (500500)`

它们是快速自检，不等价于官方 `mem/sum/vga` 全量程序。

## Mac 上运行

1. 安装仿真器
   - `brew install icarus-verilog`

2. 准备样例
   - 需要文件：`mem.hex/sum.hex/vga.hex`

3. 跑测试（包含图形）
   - `make test-official`

4. 单项运行
   - `make run-official-mem`
   - `make run-official-sum`
   - `make run-official-vga`

5. 查看图像输出
   - 生成文件：`build/vga.ppm`
   - macOS 打开：`open build/vga.ppm`

## 说明

- 全流程不依赖 Logisim GUI，采用 HDL + Verilog + C。
- 图形显示通过 MMIO 帧缓冲建模与导图实现。
- 这个 miniRV 是"单周期实现"（CPI = 1），采用分离的指令和数据存储器接口：
  - `mem/sum`: `10000` 周期（约为文档里的 `6000` 周期的 1.67 倍，考虑到实际指令数）
  - `vga`: `650000` 周期（约为文档里的 `628000` 周期）
- `iverilog` 在大内存 testbench 上编译会比较慢（几十秒到 1 分钟左右），不是死锁。

## 当前流程与标准流程区别

### 本项目

- 仿真器：`iverilog + vvp`（纯命令行）
- 测试入口：`Makefile` 一键跑 `mem/sum/vga`
- 程序加载：先把官方 `v3.0 hex words addressed` 转成逐行 32 位 hex（`tools/logisim_hex_to_words.c`）
- 图形验证：记录 VGA 写事件，再转成 `PPM`（`build/vga.ppm`）进行结果检查
- 核心微架构：单周期（CPI = 1），采用分离的指令和数据存储器接口

### 标准 Logisim 流程

- 仿真器：Logisim GUI 电路级仿真
- 程序加载：直接在 ROM/存储器组件里加载课程提供的 hex
- 图形观察：直接在 Logisim 的 VGA 组件窗口看输出
- 判定方式：主要看窗口显示和寄存器/PC 是否符合文档

### 标准 Vivado 流程

- 仿真器：Vivado Simulator（xsim）或第三方（如 Questa）
- 结果形式：testbench 波形（WDB/VCD）+ 断言 + 自动回归
- 上板流程：综合、布局布线、时序收敛、bitstream 下载到 FPGA
- 外设验证：通过板载 VGA/HDMI/UART 等真实 IO 验证，不只是行为级仿真
