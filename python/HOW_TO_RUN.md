# 怎么发送和接收一帧 OFDM（AD9361 实测流程）

本文档记录用 `tx_ad9361.py` / `rx_ad9361.py` 通过 AD9361 实际收发一帧 OFDM
数据的操作步骤，基于一次真实跑通的会话整理。协议细节见
[FRAME_AND_RX_PIPELINE.md](FRAME_AND_RX_PIPELINE.md)，硬件模式的参数说明见
[README.md](README.md#3-ad9361-hardware-mode)。

## 0. 前提

```bash
python -m pip install numpy pyadi-iio
```

两个脚本都要在 `python/` 目录下运行（不是 `python/ofdm/`——那是被
`import ofdm` 用的包目录，没有可执行脚本）：

```bash
cd O:\python
```

在错误目录（比如 `O:\python\ofdm`）运行会直接报
`No such file or directory`。

## 1. 先启动接收端，进入监听状态

```bash
python rx_ad9361.py --uri ip:192.168.33.31 --fc 2400000000 --fs 1000000 --gain 30 --threshold 0.5
```

`rx_ad9361.py` 是常驻程序，不是"发一条指令去收一次"：它开一个后台线程
不停 `sdr.rx()` 抓 IQ 放进队列，主线程不断计算与已知前导码的归一化相关
分数，分数没过 `--threshold` 就只打印 `...listening (best score=...)`，
过了才尝试完整解码。启动后会先打印一遍参数，然后停在监听状态等 TX：

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

## 2. 另开一个终端，发一帧

```bash
cd O:\python
python tx_ad9361.py --uri ip:192.168.33.31 --fc 2400000000 --fs 1000000 --gain -20 --message "HELLO OFDM FROM AD9361" --repeat 1
```

`tx_ad9361.py` 每次运行只发**一次性的单次突发**（`tx_cyclic_buffer = False`），
发完就调用 `tx_destroy_buffer()` 退出，不会循环重发：

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

## 3. 回到 RX 终端看结果

RX 那边如果在监听窗口里接住了这次突发，会打印解码结果然后继续监听：

```text
[10:20:34] packet #1  score=0.96  CFO=-59.7Hz  CRC OK
           message: 'HELLO OFDM FROM AD9361'
  ...listening (best score=0.04)
```

- `score`：与已知前导码的归一化相关值（0~1），越接近 1 越像是真的包
- `CFO`：估计出的载波频偏
- `CRC OK` / `CRC FAIL`：payload 的 CRC32 校验结果

`Ctrl+C` 停止 RX，会打印总共解码成功/CRC 失败的包数。

## 4. 为什么 RX 有时候收不到

- TX 只发一次、时长很短（本例 0.91 ms），而 RX 是按 `--buf`（默认 32768
  samples ≈ 32.8 ms）一块一块轮询的，如果这次突发正好卡在两次抓取之间
  的空隙就会被完全错过——这也是 `tx_ad9361.py` 提供 `--repeat` 参数的
  原因：一次突发里塞多份拷贝，增加落在某个抓取窗口内的概率。
- `--overlap` 让 RX 在两个抓取块之间保留一段重叠样本，缓解突发刚好卡在
  块边界被切成两半、任何一个窗口都看不全的问题。
- 分数低于 `--threshold` 时不会尝试解码，如果始终收不到包，可以先把
  `--threshold` 调低，看看 best score 大概是多少，或者调大 `--gain`
  /`--repeat`。
