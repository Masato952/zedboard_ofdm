from __future__ import annotations

import argparse
import datetime as dt
import queue
import threading

import numpy as np

from ofdm import OFDMConfig, decode_frame, make_preamble
from ofdm.core import detect_frame_start


def _capture_worker(
    sdr, buf_queue: "queue.Queue[np.ndarray]", stop_event: threading.Event
) -> None:
    """Runs on its own thread, doing nothing but back-to-back sdr.rx() calls.

    This is the whole point: a real WiFi chip's burst detector runs in
    dedicated hardware that samples continuously, in parallel with whatever
    the rest of the receiver is doing with previously-captured data. Here we
    fake that separation with a thread -- this loop never waits on
    correlation/decode, so the *capture* side stays back-to-back regardless
    of how slow Python's processing of the previous buffer is. If the
    consumer falls behind, we drop the oldest queued buffer rather than
    block the capture loop (staying current matters more than a full
    backlog).
    """
    while not stop_event.is_set():
        rx = np.asarray(sdr.rx(), dtype=np.complex64)
        try:
            buf_queue.put_nowait(rx)
        except queue.Full:
            try:
                buf_queue.get_nowait()
            except queue.Empty:
                pass
            buf_queue.put_nowait(rx)


def _normalized_score(rx: np.ndarray, template: np.ndarray, start: int, metric: np.ndarray) -> float:
    """Correlation peak normalized to [0, 1] by Cauchy-Schwarz.

    1.0 means the window at `start` is a perfect (scaled) copy of the known
    preamble; noise-only windows score much lower. This lets the listening
    loop decide "is a real packet here?" *before* paying for a full decode
    attempt, the same way a real receiver's burst detector gates the rest
    of the PHY pipeline.
    """
    window = rx[start : start + len(template)]
    denom = float(np.linalg.norm(window) * np.linalg.norm(template))
    if denom < 1e-12:
        return 0.0
    return float(np.abs(metric[start]) / denom)


def main() -> None:
    p = argparse.ArgumentParser(
        description="Continuously listen for and decode OFDM frames with AD9361"
    )
    p.add_argument("--uri", default="ip:192.168.33.31")
    p.add_argument("--fc", type=int, default=2_400_000_000, help="RX LO in Hz")
    p.add_argument("--fs", type=int, default=1_000_000, help="Sample rate in S/s")
    p.add_argument("--buf", type=int, default=32768, help="RX capture size per listen cycle")
    p.add_argument("--gain", type=float, default=30.0, help="Manual RX gain in dB")
    p.add_argument("--agc", action="store_true", help="Use slow_attack AGC instead of manual gain")
    p.add_argument(
        "--threshold",
        type=float,
        default=0.5,
        help="Normalized correlation score (0-1) required before attempting a decode",
    )
    p.add_argument(
        "--overlap",
        type=int,
        default=4096,
        help=(
            "Samples carried over from the tail of the previous chunk and "
            "prepended to the next one, so a short burst landing right on a "
            "chunk boundary still appears whole in at least one search window"
        ),
    )
    args = p.parse_args()

    try:
        import adi
    except ImportError as e:
        raise SystemExit("Install pyadi-iio first: pip install pyadi-iio") from e

    cfg = OFDMConfig(sample_rate=args.fs)
    template = make_preamble(cfg)

    sdr = adi.ad9361(uri=args.uri)
    sdr.sample_rate = int(args.fs)
    sdr.rx_lo = int(args.fc)
    # Same headroom rationale as tx_ad9361.py: leave margin below fs instead
    # of setting the filter exactly equal to the sample rate.
    sdr.rx_rf_bandwidth = int(min(max(args.fs * 0.95, 200_000), 56_000_000))
    sdr.rx_enabled_channels = [0]
    sdr.rx_buffer_size = int(args.buf)

    if args.agc:
        sdr.gain_control_mode_chan0 = "slow_attack"
    else:
        sdr.gain_control_mode_chan0 = "manual"
        sdr.rx_hardwaregain_chan0 = float(args.gain)

    # Flush a few old buffers.
    for _ in range(3):
        sdr.rx()

    print("=== AD9361 OFDM RX (continuous listening, threaded capture) ===")
    print(f"URI            : {args.uri}")
    print(f"LO             : {args.fc / 1e9:.6f} GHz")
    print(f"Sample rate    : {args.fs:,} S/s")
    print(f"Capture size   : {args.buf} samples ({args.buf / args.fs * 1e3:.1f} ms/cycle)")
    print(f"Overlap        : {args.overlap} samples ({args.overlap / args.fs * 1e3:.2f} ms)")
    print(f"Score threshold: {args.threshold}")
    print("Listening... Ctrl+C to stop.\n")

    packet_count = 0
    crc_fail_count = 0

    # Capture runs on its own thread so it never waits on correlation/decode
    # -- see _capture_worker's docstring. maxsize=2 keeps this loop from
    # ever processing badly stale data if it falls behind.
    buf_queue: "queue.Queue[np.ndarray]" = queue.Queue(maxsize=2)
    stop_event = threading.Event()
    capture_thread = threading.Thread(
        target=_capture_worker, args=(sdr, buf_queue, stop_event), daemon=True
    )
    capture_thread.start()

    prev_tail = np.zeros(0, dtype=np.complex64)

    try:
        while True:
            rx = buf_queue.get()
            combined = np.concatenate([prev_tail, rx]) if len(prev_tail) else rx
            prev_tail = rx[-args.overlap :] if len(rx) > args.overlap else rx.copy()

            start, metric = detect_frame_start(combined, cfg)
            score = _normalized_score(combined, template, start, metric)

            if score < args.threshold:
                print(f"\r  ...listening (best score={score:.2f})   ", end="", flush=True)
                continue

            # Score looks like a real preamble -- worth paying for a full decode.
            try:
                result = decode_frame(combined, cfg)
            except Exception as e:
                print(f"\n[score={score:.2f}] preamble-like signal seen but decode failed: {e}")
                continue

            # This packet has now been fully consumed -- don't let it
            # reappear in the next window via the overlap carry-over.
            prev_tail = np.zeros(0, dtype=np.complex64)

            packet_count += 1
            if not result["crc_ok"]:
                crc_fail_count += 1
            ts = dt.datetime.now().strftime("%H:%M:%S")
            status = "CRC OK" if result["crc_ok"] else "CRC FAIL"
            message = result["payload"].decode("utf-8", errors="replace")
            print(
                f"\n[{ts}] packet #{packet_count}  score={score:.2f}  "
                f"CFO={result['cfo_hz']:+.1f}Hz  {status}"
            )
            print(f"           message: {message!r}")
    except KeyboardInterrupt:
        print(
            f"\n\nStopped. Decoded {packet_count} packet(s), "
            f"{crc_fail_count} CRC failure(s)."
        )
    finally:
        stop_event.set()


if __name__ == "__main__":
    main()
