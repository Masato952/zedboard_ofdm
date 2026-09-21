# ZedBoard + AD9361：ADI Kuiper、Vivado HDL 与 Python OFDM 环境搭建记录

> 当前记录时间：2026-09-16  
> 当前硬件：ZedBoard + AD9361（AD-FMCOMMS2/AD-FMCOMMS3 系列参考设计）  
> 当前目标：先用 Python 完成 OFDM 收发，再逐步把 IFFT/FFT、CP、同步等模块迁移到 Zynq PL

---

## 0. 当前已经验证成功的版本组合

目前这套环境已经实际跑通，建议暂时不要升级版本：

| 项目 | 当前使用版本 |
|---|---|
| FPGA 板 | ZedBoard |
| RF | AD9361 / FMCOMMS2/3 参考设计 |
| Vivado | **2022.2** |
| ADI HDL | **2022_r2 Patch1 / `hdl_2022_r2` 系列** |
| 当前 HDL commit | `ae6e248f219a5bb2e63733c762e9561c072d037e` |
| Kuiper Linux | **2022_R2 Patch2** |
| Kuiper 镜像 | `image_2024-06-18-ADI-Kuiper-full.img` |
| Python 接口 | `pyadi-iio` |

这个组合是匹配的。ADI 的 **2022_R2 Patch2 Kuiper** 主要更新了 Kuiper/Linux/pyadi-iio；HDL 等其他组件仍沿用 **2022_R2 Patch1**。因此我们现在使用 **Vivado 2022.2 + HDL Patch1 + Kuiper Patch2** 是合理的。

当前 ZedBoard 中也已经通过 AXI GPIO 版本寄存器确认新 PL 加载成功：

```bash
root@analog:~# busybox devmem 0x41200000 32
0x20260916
```

---

# 1. ADI Kuiper image：在哪里下载、如何制作 SD 卡

## 1.1 Kuiper 是什么

Kuiper 是 Analog Devices 提供的、针对 ADI FPGA/RF 开发板准备好的 Debian Linux 镜像。

它已经集成了很多我们需要的东西，例如：

- Linux kernel
- AD9361/IIO 驱动
- libiio
- IIO Oscilloscope
- pyadi-iio 相关环境
- 各种 ADI 板卡的 BOOT.BIN / devicetree

因此对于 ZedBoard + AD9361，最简单的办法不是自己从零制作 Linux，而是直接使用 ADI 官方 Kuiper image。

---

## 1.2 当前使用的历史版本下载位置

ADI Kuiper 官方历史版本页面：

<https://wiki.analog.com/resources/tools-software/linux-software/adi-kuiper_images/release_notes>

我们当前使用的是：

```text
2022_R2 Patch2
18 June 2024 release
```

官方历史镜像直接下载地址：

<https://swdownloads.analog.com/cse/kuiper/image_2024-06-18-ADI-Kuiper-full.zip>

下载后解压得到类似：

```text
image_2024-06-18-ADI-Kuiper-full.img
```

> 对当前工程而言，建议保存好这份历史镜像，不要因为官网出现新 Kuiper 就马上升级。新版本可能对应不同内核、不同 HDL 和不同 Vivado 版本。

---

## 1.3 如何把 `.img` 写入 SD 卡

Windows 下可以使用：

- Balena Etcher
- Win32 Disk Imager
- ADI Kuiper Imager

基本流程：

```text
下载 ZIP
  ↓
解压得到 .img
  ↓
插入 SD 卡
  ↓
使用镜像工具选择 .img
  ↓
写入 SD 卡
```

Kuiper 会建立 Linux 所需要的分区，不要直接把 `.img` 当普通文件复制到 SD 卡。

ADI Kuiper 使用说明：

<https://wiki.analog.com/resources/tools-software/linux-software/kuiper-linux>

---

## 1.4 ZedBoard + FMCOMMS2/3 对应的 boot 文件

对于 ZedBoard + AD9361 FMCOMMS2/3，Kuiper 的 boot 分区中会提供对应工程。

旧版 Kuiper 中常见名称类似：

```text
zynq-zed-adv7511-ad9361-fmcomms2-3
```

ADI 官方说明中，Zynq 平台启动时根目录通常需要：

```text
BOOT.BIN
devicetree.dtb
uImage
```

对应关系大致是：

```text
目标工程/BOOT.BIN            -> SD BOOT 根目录/BOOT.BIN
目标工程/devicetree.dtb      -> SD BOOT 根目录/devicetree.dtb
zynq-common/uImage           -> SD BOOT 根目录/uImage
```

我们后面自己修改 Vivado PL 时，通常只替换自己重新生成的：

```text
BOOT.BIN
```

Linux rootfs、uImage、devicetree 暂时保持原来的即可，除非设计中的设备树结构也发生变化。

---

## 1.5 是否需要自己“生成 Kuiper image”

目前**不需要**。

当前项目最稳妥的方法是：

```text
使用 ADI 官方 2022_R2 Patch2 image
+
自己修改 Vivado bitstream / BOOT.BIN
```

Kuiper 本身也有开源仓库：

<https://github.com/analogdevicesinc/kuiper>

但新版 Kuiper 的构建体系已经发生变化。如果目的是继续当前 ZedBoard + AD9361 OFDM 项目，不建议现在花时间重新从源码制作整个 Linux image。

---

# 2. ADI 官方 Vivado HDL：在哪里下载、如何生成 ZedBoard 工程

## 2.1 ADI 官方 HDL 仓库

官方源码：

<https://github.com/analogdevicesinc/hdl>

官方 HDL 编译说明：

<https://analogdevicesinc.github.io/hdl/user_guide/build_hdl.html>

这个仓库里包含：

```text
hdl/
├─ library/        ADI 自己的 AXI IP
├─ projects/       各类开发板工程
├─ scripts/        公共 Tcl / make 脚本
└─ ...
```

我们使用的工程在：

```text
hdl/projects/fmcomms2/zed
```

也就是：

```text
FMCOMMS2/3
+
ZedBoard
```

---

## 2.2 下载 HDL 源码

建议使用 Git：

```bash
git clone https://github.com/analogdevicesinc/hdl.git
cd hdl
```

不要直接使用最新 `main`，因为它可能要求更新的 Vivado。

当前项目应使用 2022_r2 系列。

推荐固定到我们已经验证过的 Patch1：

```bash
git checkout 2022_r2_p1
```

如果以后 tag 名称有问题，也可以直接固定到当前已经验证的 commit：

```bash
git checkout ae6e248f219a5bb2e63733c762e9561c072d037e
```

这个版本对应：

```text
Vivado 2022.2
```

不要用 Vivado 2023.x / 2024.x 直接打开后随意 Upgrade IP，否则会让工程和 Kuiper 官方版本越来越难对应。

---

## 2.3 当前电脑上的 HDL 路径

本次实际使用路径：

```text
C:\aGitCode\work\02_Projects\zedboard\adi\hdl
```

ZedBoard + FMCOMMS2 工程目录：

```text
C:\aGitCode\work\02_Projects\zedboard\adi\hdl\projects\fmcomms2\zed
```

当前 Vivado 工程：

```text
fmcomms2_zed.xpr
```

完整示例：

```text
C:\aGitCode\work\02_Projects\zedboard\adi\hdl\projects\fmcomms2\zed\fmcomms2_zed.xpr
```

---

## 2.4 官方推荐的工程生成方法：make

ADI 官方推荐使用 GNU Make 生成工程。

进入：

```bash
cd hdl/projects/fmcomms2/zed
```

执行：

```bash
make
```

`make` 会做的事情可以理解为：

```text
构建 ADI 所需 IP
    ↓
运行 system_project.tcl
    ↓
建立 Vivado Block Design
    ↓
综合 Synthesis
    ↓
实现 Implementation
    ↓
生成 bitstream / XSA
```

正常完成后，就可以打开生成的 Vivado `.xpr` 工程继续查看和修改。

---

## 2.5 也可以在 Vivado Tcl Console 中生成工程

ADI 的工程本质上是由 Tcl 脚本建立的。

在 Vivado 2022.2 中进入 Tcl Console，可以进入工程目录：

```tcl
cd {C:/aGitCode/work/02_Projects/zedboard/adi/hdl/projects/fmcomms2/zed}
```

ADI 的现代构建文档中也提供类似流程：

```tcl
source ../../scripts/adi_make.tcl
adi_make::lib all
source ./system_project.tcl
```

对于我们当前已生成好的工程，平时不需要反复重新从零运行这些命令；直接打开 `.xpr` 修改即可。

---

## 2.6 ADI 官方工程的基本结构

当前 AD9361 的 FPGA 数据链可以粗略理解成：

```text
AD9361 RF
   ↕
AD9361 数字接口
   ↕
axi_ad9361
   ↕
pack/unpack / DMA
   ↕
DDR / ARM/Linux
   ↕
libiio / pyadi-iio
   ↕
PC Python
```

现在 Python OFDM 是：

```text
Python 生成 OFDM IQ
        ↓
libiio / Ethernet
        ↓
Linux / DMA
        ↓
axi_ad9361
        ↓
AD9361 TX
```

接收方向反过来。

后面的目标不是把 `axi_ad9361` 改掉，而是在它的数据通路中加入自己的：

```text
my_ofdm_tx
my_ofdm_rx
```

例如未来 TX：

```text
ARM/DMA
   ↓
QPSK/Subcarrier Mapper
   ↓
64-point IFFT
   ↓
Add CP
   ↓
axi_ad9361
   ↓
AD9361
```

---

## 2.7 修改 Vivado 后重新生成 bitstream

在 Vivado GUI 中：

```text
Validate Design
   ↓
Generate Bitstream
```

最终得到新的：

```text
system_top.bit
```

我们当前将用于 bootgen 的相关文件放在：

```text
C:\aGitCode\work\02_Projects\zedboard\adi\hdl\projects\fmcomms2\zed\bootgen_sysfiles
```

其中类似：

```text
fsbl.elf
system_top.bit
u-boot_zynq_zed.elf
zynq.bif
```

`zynq.bif` 的结构类似：

```text
the_ROM_image:
{
    [bootloader] fsbl.elf
    system_top.bit
    u-boot_zynq_zed.elf
}
```

---

## 2.8 重新生成 BOOT.BIN

如果当前在 **Vivado Tcl Console**，不要使用 CMD 的 `cd /d`。

使用：

```tcl
cd {C:/aGitCode/work/02_Projects/zedboard/adi/hdl/projects/fmcomms2/zed/bootgen_sysfiles}
```

然后：

```tcl
exec bootgen -image zynq.bif -arch zynq -o BOOT.BIN -w on
```

生成新的：

```text
BOOT.BIN
```

然后将它复制到 SD 卡 BOOT 分区根目录，覆盖原来的 `BOOT.BIN`。

之后 ZedBoard **断电再启动**。

---

## 2.9 当前已经加入的 PL 版本确认方法

为了确认 ZedBoard 当前到底运行的是不是刚生成的 PL，我们在 Block Design 中加入了：

```text
xlconstant_0
    Const Width = 32
    Const Value = 539363606 (十进制)
                = 0x20260916
        ↓
axi_gpio_0 / gpio_io_i[31:0]
        ↓
S_AXI
        ↓
PS M_AXI_GP0
```

AXI GPIO 地址：

```text
0x41200000
```

Linux 中执行：

```bash
busybox devmem 0x41200000 32
```

当前实际返回：

```text
0x20260916
```

这说明：

```text
新的 Vivado Block Design
        ↓
新的 system_top.bit
        ↓
新的 BOOT.BIN
        ↓
ZedBoard PL
```

这一整条链已经验证成功。

> `dmesg | grep -i sysid` 中的时间不一定代表最新一次 bitstream 生成时间。ADI 官方 release notes 也明确说明 SYSID 可能比实际最新 commit 旧。因此我们自己的 AXI 版本寄存器更直接。

### 注意

目前 `axi_gpio_0 + xlconstant_0` 是为了验证开发流程而临时加入的。

将来做正式 `my_ofdm_tx` / `my_ofdm_rx` 时，最好把：

```text
VERSION register
```

直接做进自己的 AXI-Lite 寄存器里。

另外，目前是在 Vivado GUI 中手工修改 Block Design。以后如果执行：

```bash
make clean
make
```

或者从 ADI Tcl 完全重新生成工程，GUI 中手工加入的 IP 可能丢失。等 OFDM IP 结构稳定以后，应把修改同步到 ADI 的 Tcl 工程脚本中。

---

# 3. Python OFDM：当前代码是如何实现的

## 3.1 当前 Python 工程

当前已经建立：

```text
ad9361_ofdm_python_v0.1.zip
```

工程结构：

```text
ad9361_ofdm_python/
├─ ofdm/
│  ├─ __init__.py
│  ├─ core.py
│  └─ channel.py
├─ sim_demo.py
├─ tx_ad9361.py
├─ rx_ad9361.py
├─ requirements.txt
└─ README.md
```

功能分工：

```text
core.py
    OFDM 调制、解调、同步、CFO、信道估计、CRC

channel.py
    Python 模拟信道：delay / multipath / CFO / AWGN

sim_demo.py
    不需要硬件，纯 Python 验证 OFDM 算法

tx_ad9361.py
    通过 pyadi-iio 控制 AD9361 发送

rx_ad9361.py
    通过 pyadi-iio 获取 IQ 并解调 OFDM
```

---

## 3.2 当前 OFDM 参数

目前故意做成比较简单、容易理解的 OFDM，不是完整 IEEE 802.11 协议。

```text
FFT / IFFT     = 64 点
CP             = 16 samples
占用子载波     = -26 ... -1, +1 ... +26
DC             = 0，不使用
Pilot          = -21, -7, +7, +21
Data carriers  = 48
调制           = QPSK
每个 QPSK      = 2 bits
每个 OFDM symbol = 48 × 2 = 96 bits
```

当前默认采样率：

```text
Fs = 1 MHz
```

所以：

```text
子载波间隔 = Fs / 64
           = 15.625 kHz
```

以后把采样率提高到 20 MHz 时：

```text
子载波间隔 = 20 MHz / 64
           = 312.5 kHz
```

这时 64 FFT + CP16 的时间结构就和经典 802.11a/g 很接近：

```text
有效符号 3.2 us
CP       0.8 us
总符号   4.0 us
```

---

## 3.3 发射端 OFDM 生成流程

Python TX 基本流程：

```text
字符串 / payload
      ↓
MAGIC + LENGTH + payload + CRC32
      ↓
bytes → bits
      ↓
QPSK mapping
      ↓
放入 48 个 Data subcarriers
+ 4 个 Pilot
      ↓
64-point IFFT
      ↓
添加 CP16
      ↓
多个 OFDM symbols
      ↓
前面加两个 Training OFDM symbols
      ↓
得到 complex IQ
      ↓
pyadi-iio
      ↓
AD9361 TX
```

---

## 3.4 Packet 格式

现在的数据包格式：

```text
MAGIC(2 bytes)
+
LENGTH(2 bytes)
+
PAYLOAD(N bytes)
+
CRC32(4 bytes)
```

MAGIC 固定为：

```python
MAGIC = b"OF"
```

例如 payload：

```text
HELLO OFDM - ZedBoard AD9361
```

接收机先解出头部，再根据 LENGTH 判断还需要接收多少 OFDM symbol。

---

## 3.5 QPSK mapping

当前 QPSK：

```text
00 → +1 + j
01 → +1 - j
10 → -1 + j
11 → -1 - j
```

最后除以：

```text
sqrt(2)
```

所以星座点大致是：

```text
(+0.707, +0.707)
(+0.707, -0.707)
(-0.707, +0.707)
(-0.707, -0.707)
```

---

## 3.6 64 个 frequency bins 如何使用

逻辑子载波编号：

```text
-32 ... -1, 0, +1 ... +31
```

但 NumPy 数组索引是：

```text
0 ... 63
```

因此代码使用：

```python
np.mod(k, 64)
```

把 signed subcarrier 转成 NumPy bin index。

例如：

```text
k = +1  → index 1
k = +26 → index 26
k = -26 → index 38
k = -1  → index 63
```

---

## 3.7 IFFT 和 CP

每一个 payload OFDM symbol 首先在频域建立：

```text
64 个 complex bins
```

然后：

```python
np.fft.ifft(x)
```

得到：

```text
64 个时域 complex IQ samples
```

再把最后 16 个 sample 复制到最前面：

```text
64 samples
↓
最后 16 samples 复制到前面
↓
16 CP + 64 useful
↓
80 samples / OFDM symbol
```

代码对应：

```python
def add_cp(time_symbol, cp_len):
    return np.concatenate([time_symbol[-cp_len:], time_symbol])
```

---

## 3.8 Preamble / Training

现在的 preamble 使用两个完全相同的训练 OFDM symbol：

```text
Training #1 = CP16 + 64 samples
Training #2 = CP16 + 64 samples
```

所以 preamble 共：

```text
80 + 80 = 160 samples
```

训练 symbol 的频域内容是接收端已知的固定 BPSK 序列。

它主要做三件事情：

```text
1. packet detection
2. CFO estimation
3. channel estimation
```

---

## 3.9 接收端流程

RX 的完整逻辑：

```text
AD9361 RX complex IQ
        ↓
与已知 preamble 做 correlation
        ↓
找到 frame start
        ↓
比较两个重复 training 的相位
        ↓
估计 CFO
        ↓
整个 frame 做 CFO correction
        ↓
training 去 CP + FFT
        ↓
Ytrain / Xtrain
        ↓
估计 H[k]
        ↓
payload 去 CP + FFT
        ↓
Y[k] / H[k]
        ↓
pilot phase correction
        ↓
取出 48 个 data carriers
        ↓
QPSK demap
        ↓
bits → bytes
        ↓
MAGIC / LENGTH / CRC32
```

---

## 3.10 先在纯 Python 中验证

安装：

```bash
python -m pip install numpy matplotlib
```

运行：

```bash
python sim_demo.py
```

正常情况下应看到类似：

```text
CRC            : PASS
RX message     : HELLO OFDM - ZedBoard AD9361
```

还可以人为增加信道困难：

```bash
python sim_demo.py --snr 15 --cfo 2000
```

这样可以先确认算法没有问题，再去排查 RF/FPGA 问题。

---

## 3.11 使用 pyadi-iio 控制 AD9361

pyadi-iio 官方文档：

<https://analogdevicesinc.github.io/pyadi-iio/>

安装：

```bash
python -m pip install pyadi-iio
```

核心控制方式非常简单：

```python
import adi

sdr = adi.ad9361(uri="ip:192.168.2.1")

sdr.sample_rate = 1_000_000
sdr.tx_lo = 2_400_000_000
sdr.rx_lo = 2_400_000_000

sdr.tx(iq)
rx = sdr.rx()
```

所以可以理解为：

```text
PC Python
   ↓ Ethernet / libiio
ZedBoard Linux IIO driver
   ↓ DMA
FPGA axi_ad9361
   ↓
AD9361
```

并不是在 ZedBoard Linux 上必须运行 Python 才能控制 AD9361；PC 上的 Python 可以通过网络直接控制 ZedBoard 上的 IIO 设备。

---

## 3.12 当前 AD9361 OFDM TX 命令

例如：

```bash
python tx_ad9361.py \
  --uri ip:192.168.2.1 \
  --fc 2400000000 \
  --fs 1000000 \
  --gain -50 \
  --message "HELLO AD9361 OFDM"
```

当前 TX 使用：

```python
sdr.tx_cyclic_buffer = True
```

所以一个：

```text
OFDM frame + guard zeros
```

会不断循环发送。

这也是为什么 RX correlation 图中会看到很多周期性的高峰。

---

## 3.13 当前 AD9361 OFDM RX 命令

例如：

```bash
python rx_ad9361.py \
  --uri ip:192.168.2.1 \
  --fc 2400000000 \
  --fs 1000000 \
  --gain 30
```

正常时会输出：

```text
Detected start : ... samples
Estimated CFO  : ... Hz
CRC            : PASS
RX message     : ...
```

并画出：

```text
Packet correlation
QPSK constellation
```

---

# 4. 当前项目已经做到哪里

目前完成的路线：

```text
[完成] 官方 Kuiper Linux 启动 ZedBoard
     ↓
[完成] ZedBoard + AD9361 IIO 工作
     ↓
[完成] PC Python 通过 pyadi-iio 控制 AD9361
     ↓
[完成] Python 64-point QPSK OFDM
     ↓
[完成] Preamble / packet detect
     ↓
[完成] CFO estimation / correction
     ↓
[完成] channel estimation / equalization
     ↓
[完成] CRC PASS
     ↓
[完成] Vivado 2022.2 生成 ADI fmcomms2/zed 工程
     ↓
[完成] 修改 Block Design
     ↓
[完成] 重新 Generate Bitstream
     ↓
[完成] bootgen 重新制作 BOOT.BIN
     ↓
[完成] AXI GPIO 版本寄存器验证新 PL 已加载
     ↓
[下一步] Xilinx 64-point FFT IP：先做 IFFT 单模块验证
```

---

# 5. 下一步建议：开始把 OFDM 搬进 PL

第一步不要直接做完整 OFDM。

先做：

```text
Python / NumPy
64 complex frequency bins
        ↓
np.fft.ifft()
        ↓
Golden output
```

和 FPGA：

```text
64 complex frequency bins
        ↓
Xilinx FFT IP (IFFT mode)
        ↓
FPGA output
```

逐 sample 比较：

```text
NumPy IFFT output
vs
Xilinx FFT/IFFT IP output
```

先解决：

- AXI Stream 数据格式
- I/Q 位宽
- fixed-point scaling
- FFT bin 顺序
- TLAST
- FFT configuration channel

完全一致以后，再加：

```text
IFFT
 ↓
CP16
 ↓
AD9361 TX
```

之后再逐步做 RX：

```text
packet detector
→ timing
→ CFO
→ CP removal
→ FFT
→ channel equalizer
→ QPSK demapper
```

这样每一步都可以继续用 Python 作为 **Golden Model** 对 FPGA 结果做比较。

---

# 6. 官方资料汇总

ADI Kuiper 历史 release notes：

<https://wiki.analog.com/resources/tools-software/linux-software/adi-kuiper_images/release_notes>

2022_R2 Patch2 历史 image：

<https://swdownloads.analog.com/cse/kuiper/image_2024-06-18-ADI-Kuiper-full.zip>

Kuiper 使用说明：

<https://wiki.analog.com/resources/tools-software/linux-software/kuiper-linux>

ADI HDL GitHub：

<https://github.com/analogdevicesinc/hdl>

ADI HDL Build Guide：

<https://analogdevicesinc.github.io/hdl/user_guide/build_hdl.html>

pyadi-iio：

<https://analogdevicesinc.github.io/pyadi-iio/>

---

## 最重要的版本原则

当前工程先固定：

```text
Kuiper 2022_R2 Patch2
+ HDL 2022_r2 Patch1
+ Vivado 2022.2
+ ZedBoard
+ AD9361
```

在 OFDM PL 化完成以前，不建议为了“版本新”而升级 Vivado、HDL 或 Kuiper。

现在我们已经证明：

```text
Python OFDM 可以工作
Vivado ADI 工程可以修改
bitstream 可以重新生成
BOOT.BIN 可以重新制作
ZedBoard 可以加载自己的新 PL
ARM/Linux 可以读取自己加入的 AXI 寄存器
```

因此下一阶段可以正式开始自定义 OFDM FPGA IP。
