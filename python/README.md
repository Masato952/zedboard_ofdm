# AD9361 OFDM Python — v0.1

一个刻意写得简单、便于理解的 OFDM 收发实现，用来先在 Python/PC 上跑通整
条链路，之后再逐步把 IFFT/FFT、CP、同步等模块迁移进 Zynq PL。

**目前不是完整的 IEEE 802.11 实现**，只是频域分配仿 802.11a，方便以后对齐。

## 目录结构

```text
python/
├─ ofdm/
│  ├─ core.py       OFDM 调制/解调、同步、CFO、信道估计、CRC
│  └─ channel.py    纯 Python 信道仿真：延迟/多径/CFO/AWGN
├─ sim_demo.py      不需要硬件，纯算法验证，从这里开始
├─ tx_ad9361.py     通过 pyadi-iio 控制 AD9361 发送
├─ rx_ad9361.py     通过 pyadi-iio 控制 AD9361 接收并解码
└─ requirements.txt
```

## 1. 当前 PHY 参数

| 参数 | 数值 |
|---|---|
| FFT / IFFT 点数 | 64 |
| 循环前缀 CP | 16 samples |
| 每个 OFDM symbol 总长 | 80 samples (CP16 + 64) |
| 占用子载波 | `-26..-1, +1..+26`（共 52 个，仿 802.11a，跳过直流） |
| 导频子载波 | `-21, -7, +7, +21`（4 个，固定已知值） |
| 数据子载波 | 剩余 48 个 |
| 调制方式 | QPSK（每子载波 2 bit） |
| 每个 OFDM symbol 比特数 | 48 × 2 = 96 bit |
| 默认采样率 | 1,000,000 S/s |

子载波间隔 = Fs / 64。默认 1 MHz 采样率下是 15.625 kHz；以后提到 20 MHz
时会变成 312.5 kHz，此时 64 点 FFT + CP16 的时长结构（3.2 μs 符号 + 0.8
μs CP = 4.0 μs）就和经典 802.11a/g 很接近了。

## 2. 一帧数据长什么样

以默认示例消息 `"HELLO OFDM - ZedBoard AD9361"`（28 字节）为例：

```text
┌──────────────┬──────────────┬──────────────┬──────────────┬──────────────┐
│ Training #1  │ Training #2  │ Payload #0   │ Payload #1   │ Payload #2   │
│ CP16 + 64    │ CP16 + 64    │ CP16 + 64    │ CP16 + 64    │ CP16 + 64    │
│ = 80 samples │ = 80 samples │ = 80 samples │ = 80 samples │ = 80 samples │
└──────────────┴──────────────┴──────────────┴──────────────┴──────────────┘
   sample 0~79     80~159        160~239        240~319        320~399

总长度 = 5 × 80 = 400 samples
```

**前两个符号（训练符号）负责"帮 RX 找到包、估频偏、估信道"，后面的数据
符号才是真正装消息内容的地方。** 这是最核心的分工原则。

Payload 里装的是：

```text
raw_packet = MAGIC(2字节="OF") + LENGTH(2字节) + PAYLOAD(消息本身) + CRC32(4字节)
```

代入例子：`2 + 2 + 28 + 4 = 36 字节 = 288 bit`，`288 / 96 = 3`，所以正好
需要 3 个 payload 符号。

训练符号用固定种子 `np.random.default_rng(0x9361)` 生成 52 个 BPSK 比
特，TX、RX 各自独立生成同一份数据，不需要真的传输"密码本"。

### 2.1 一个 payload 符号：12 字节怎么变成 80 个采样点

上面每个 `Payload #0/#1/#2` 都是 80 个采样点，但装的数据其实只有 12
字节（96 bit ÷ 96bit/符号）。这 80 个数不是"12字节直接铺开"得到的，
中间要经过 QPSK 映射 + 塞进频谱 + IFFT 三次变换，`_make_payload_symbol`
（[ofdm/core.py:147-160](ofdm/core.py#L147-L160)）里做的就是这件事：

```text
第0步：12 字节 = 96 bit
┌────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┬────┐
│ B0 │ B1 │ B2 │ B3 │ B4 │ B5 │ B6 │ B7 │ B8 │ B9 │B10 │B11 │   12 bytes
└────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┴────┘
      每 2 bit 切一份，过 qpsk_map()
      00→+1+1j  01→+1-1j  10→-1+1j  11→-1-1j （再除以 √2 归一化）
                          ▼
第1步：48 个 QPSK 复数符号（96bit ÷ 2bit = 48，数量不变，只是换了表示）
┌─────┬─────┬─────┬─────┬─────┬─────┐
│ S0  │ S1  │ S2  │ ...  │ S46 │ S47 │   48 个复数点
└─────┴─────┴─────┴─────┴─────┴─────┘
      按 data_k 这张"子载波编号表"，塞进64点频谱数组的指定位置
                          ▼
第2步：64点频域数组 x[0..63]（NumPy bin，用 np.mod(k,64) 把 -26..+26 换算成 0..63）
┌───────────────────────────────────────────────────────────────┐
│ bin0(DC)=0 │ 48个bin = S0..S47(data_k) │ 4个bin = 固定pilot值 │ 12个bin(两端保护带)=0 │
└───────────────────────────────────────────────────────────────┘
      共 64 格：48 格是你的数据、4 格是固定已知的 pilot、12 格本来就不用永远是 0
      np.fft.ifft(x)  ← 64点频域进，64点时域出，点数由 nfft=64 决定，跟数据量无关
                          ▼
第3步：64个时域复数采样点 t[0..63]
┌────┬────┬────┬────┬─────┬─────┐
│ t0 │ t1 │ t2 │ ... │ t62 │ t63 │   每个 t[n] 是全部64个频域值的加权叠加
└────┴────┴────┴────┴─────┴─────┘
      注意：这一步之后已经看不出"第几个字节对应第几个采样点"了——
      IFFT 把 48 个数据子载波的信息混合叠加进了全部 64 个时域点里，
      这正是 OFDM 名字里 "正交频分复用" 的意思。
      把最后 16 个点(t48..t63)复制一份到最前面，当循环前缀(CP)
                          ▼
第4步：80 个采样点 = 1 个 payload OFDM symbol
┌───────────────────┬──────────────────────────────────────────┐
│  CP = t48..t63     │              Body = t0..t63               │
│    16 samples      │                64 samples                 │
└───────────────────┴──────────────────────────────────────────┘
      = 80 samples，就是最上面那张表里 "Payload #0 = 80 samples" 的来历
```

三个 payload 符号（36 字节的包）各自独立走一遍这四步，互不影响，最后
按顺序拼在一起就是 `Payload #0 + #1 + #2 = 240 samples`。

## 3. TX 流程

```text
字符串 payload
      ↓
MAGIC + LENGTH + payload + CRC32
      ↓
bytes → bits
      ↓
QPSK mapping（每子载波2bit）
      ↓
放入 48 个 data 子载波 + 4 个 pilot
      ↓
64-point IFFT
      ↓
添加 CP16 → 80 samples / symbol
      ↓
前面拼上两个 Training symbol（同样 CP16+64）
      ↓
complex IQ
      ↓
pyadi-iio → AD9361 TX
```

## 4. RX 流程

接收到的不是干净拷贝，前后夹着噪声，还叠加了未知延迟、多径、频偏
(CFO)、相位旋转。RX 要做的：**先找到包从哪开始，再一步步消掉这些干
扰，最后解出比特。**

1. **Packet detection（找起点）**：用完整 160 点已知 preamble（两个训
   练符号）做滑动匹配滤波相关，相关峰值最高的位置就是 `frame_start`。
2. **CFO 估计**：TX/RX 本振频率不可能完全一致，会带来随时间累积的相位
   旋转。Training#1 和 Training#2 理论上该收到完全一样的内容，实际收到
   的 #2 相对 #1 整体多转了一个固定角度，比较这个角度就能反推出 CFO。
3. **CFO 校正**：对整个 400 点 segment（不只是训练符号）做频偏旋转校
   正，因为 payload 部分同样被同一个 CFO 污染。
4. **信道估计**：用校正后的两个训练符号做 FFT，与已知训练图案相除得到
   每个子载波的信道增益 `H[k]`。
5. **逐符号解 payload**：去 CP → FFT → 除以 `H[k]` 均衡 → 用 4 个已知
   pilot 算这个符号的"共同相位误差"(CPE) 并再修正一次（CFO 只消除了随
   时间线性累积的部分，每个符号自己还有残余的非线性相位漂移，需要靠
   pilot 实时校正）→ 取出 48 个 data 子载波做 QPSK 硬判决 → 96 bit。
6. **边解边判断长度**：RX 一开始不知道 payload 有几个符号，需要先解出
   Payload#0 拿到 MAGIC("OF") + LENGTH，算出总 bit 数和需要的符号数，
   再继续解够为止，最后按 LENGTH 截出真正 payload，重新计算 CRC32 校
   验（`crc_ok`）。

也就是说"抓包"其实是两件不同的事：靠训练符号 + 相关找到 400 点数据从
哪开始（packet detection）；靠 Payload#0 解出来的头几个字节判断这批
bit 是不是我们的包、payload 有多长（MAGIC/LENGTH）。v0.1 没有单独的
PHY 信令符号，长度信息混在数据里，要先解完第一个符号才能读到。

涉及的源码位置（`ofdm/core.py`）：

| 步骤 | 函数 |
|---|---|
| 生成训练符号/前导 | `make_training_frequency` → `make_training_symbol` → `make_preamble` |
| 打包/拆包字节头 | `pack_payload` / `unpack_payload` |
| 生成一个 payload 符号 | `_make_payload_symbol` |
| 拼出完整一帧 | `build_frame` |
| 找包起点 | `detect_frame_start` |
| 估计 CFO | `estimate_cfo_from_repeated_training` |
| 校正 CFO | `correct_cfo` |
| 估计信道 | `estimate_channel` |
| 解一个 payload 符号（含 pilot 相位校正） | `_decode_one_payload_symbol` |
| 完整 RX 流程 | `decode_frame` |

## 5. 先跑纯 Python 仿真（不需要硬件）

```bash
python -m pip install numpy matplotlib
python sim_demo.py
```

期望结果大致是：

```text
CRC            : PASS
RX message     : HELLO OFDM - ZedBoard AD9361
```

也可以加大信道难度先验证算法本身没问题，再去排查 RF/FPGA 问题：

```bash
python sim_demo.py --snr 15 --cfo 2000
python sim_demo.py --snr 8 --cfo 1000
```

图里会画出包相关、均衡后的 QPSK 星座图、估计出的信道幅度。

## 6. 硬件模式：用 AD9361 实际收发

安装依赖（libiio 可用之后）：

```bash
python -m pip install pyadi-iio
```

pyadi-iio 的基本控制方式：

```python
import adi

sdr = adi.ad9361(uri="ip:192.168.2.1")
sdr.sample_rate = 1_000_000
sdr.tx_lo = 2_400_000_000
sdr.rx_lo = 2_400_000_000

sdr.tx(iq)
rx = sdr.rx()
```

链路可以理解为：

```text
PC Python
   ↓ Ethernet / libiio
ZedBoard Linux IIO driver
   ↓ DMA
FPGA axi_ad9361
   ↓
AD9361
```

PC 上的 Python 通过网络直接控制 ZedBoard 上的 IIO 设备，不需要在
ZedBoard Linux 上跑 Python。

两个脚本都必须在 `python/` 目录下运行（不是 `python/ofdm/`——那是被
`import ofdm` 用的包目录，没有可执行脚本；在错误目录运行会直接报
`No such file or directory`）：

```bash
cd python
```

### 6.1 先启动接收端进入监听

```bash
python rx_ad9361.py --uri ip:192.168.33.31 --fc 2400000000 --fs 1000000 --gain 30 --threshold 0.5
```

`rx_ad9361.py` 是常驻程序，不是"发一条指令收一次"：它开一个后台线程
不停 `sdr.rx()` 抓 IQ 放进队列，主线程不断计算与已知前导码的归一化相
关分数，分数没过 `--threshold` 就只打印 `...listening (best
score=...)`，过了才尝试完整解码：

```text
=== AD9361 OFDM RX (continuous listening, threaded capture) ===
URI            : ip:192.168.33.31
LO             : 2.400000 GHz
Sample rate    : 1,000,000 S/s
Capture size   : 32768 samples (32.8 ms/cycle)
Overlap        : 4096 samples (4.10 ms)
Score threshold: 0.5
Listening... Ctrl+C to stop.

  ...listening (best score=0.15)
```

### 6.2 另开一个终端发一帧

```bash
cd python
python tx_ad9361.py --uri ip:192.168.33.31 --fc 2400000000 --fs 1000000 --gain -20 --message "HELLO OFDM FROM AD9361" --repeat 1
```

`tx_ad9361.py` 每次运行只发**一次性单次突发**（`tx_cyclic_buffer =
False`），发完调用 `tx_destroy_buffer()` 退出，不会循环重发：

```text
=== AD9361 OFDM TX (single burst) ===
URI            : ip:192.168.33.31
LO             : 2.400000 GHz
Sample rate    : 1,000,000 S/s
TX gain        : -20.0 dB
Frame samples  : 400
Guard samples  : 512
Repeats        : 1
Total duration : 0.91 ms
Message        : 'HELLO OFDM FROM AD9361'
Burst sent.
```

### 6.3 回 RX 终端看结果

如果 RX 在监听窗口里接住了这次突发，会打印解码结果然后继续监听：

```text
[10:20:34] packet #1  score=0.96  CFO=-59.7Hz  CRC OK
           message: 'HELLO OFDM FROM AD9361'
  ...listening (best score=0.04)
```

- `score`：与已知前导码的归一化相关值（0~1），越接近 1 越像真的包
- `CFO`：估计出的载波频偏
- `CRC OK` / `CRC FAIL`：payload 的 CRC32 校验结果

`Ctrl+C` 停止 RX，会打印总共解码成功/CRC 失败的包数。

若 TX、RX 在不同板子上，把各自的 `--uri` 改成对应板子的地址。

### 6.4 为什么 RX 有时候收不到

- TX 只发一次、时长很短（例中 0.91 ms），RX 是按 `--buf`（默认 32768
  samples ≈ 32.8 ms）一块一块轮询的，如果突发正好卡在两次抓取之间的空
  隙就会被完全错过——这也是 `--repeat` 参数的意义：一次突发里塞多份拷
  贝，增加落在某个抓取窗口内的概率。
- `--overlap` 让 RX 在两个抓取块之间保留一段重叠样本，缓解突发刚好卡
  在块边界、任何一个窗口都看不全的问题。
- 分数低于 `--threshold` 不会尝试解码。始终收不到包时，可以先把
  `--threshold` 调低看看 best score 大概多少，或者调大 `--gain` /
  `--repeat`。

### 6.5 硬件安全提示

第一次真实 RF 测试，建议用**同轴线 + 合适衰减**连接 TX/RX，而不是天线
空口发射，更容易调试。**不要**在没有衰减、没确认安全输入电平的情况下
把 RF TX 输出直接接到 RX 输入。

如果要空口发射，请只使用当地法规和硬件认证允许的频率/功率/参数。

## 7. 为什么先用 1 MS/s

v0.1 的目标是让算法/调试过程可见，不是吞吐量。低采样率让 PC/IIO 抓取
更轻松。稳定之后再往 5、10、20 MS/s 走。

## 8. 开发路线图

**v0.1 — 已完成**：Python QPSK OFDM + 包检测 + CFO + 信道估计 + CRC

**v0.2**：更好的定时同步、BER/SNR 测量、16QAM 选项、带 MCS+长度的
BPSK 头部、多包/序列号

**v0.3**：802.11a 风格的 short/long training、更强的 CFO 估计器、
pilot 极性序列、卷积编码 + Viterbi

**v0.4 — 第一次迁移进 PL**：packet 生成仍留在 Python，把 **TX IFFT +
CP** 搬进 Zynq PL。验证方式：`NumPy IFFT` 输出 vs `Xilinx FFT/IFFT IP`
输出，逐 sample 比较后再上 RF。

进展（硬件已验证，ILA 逐 sample 比对 golden 值，误差在 1~2 个 LSB
量化噪声内）：
- QPSK 映射 → 64 点 IFFT（`xfft_0`，Scaled 模式 ÷64）→ CP 插入，单个
  training 符号、单个 payload 符号分别验证通过
- `ofdm_frame_sequencer` 在 training 符号和多个 payload 符号之间动态
  切换（`training1 → training2 → payload0 → payload1 → ...` 循环），
  两个 payload 符号的完整帧已验证内容正确
- 还未完成：硬件生成的输出目前只接到 ILA 调试探针，尚未接入
  `axi_ad9361` 的真实 DAC 发送链路（需要在 `util_ad9361_dac_upack` 和
  `axi_ad9361` 之间加一个源选择 mux），所以还不能真正把这条通路发射
  出去

**v0.5 — RX PL**：`AD9361 IQ → packet detector → timing/CFO → CP
removal → FFT IP → DMA to PS`

**v1.0**：完整实时 FPGA OFDM PHY，ARM/Linux 负责配置、MAC/应用数据和
监控。
