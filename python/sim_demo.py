from __future__ import annotations

import argparse

import matplotlib.pyplot as plt
import numpy as np

from ofdm import DEFAULT_CONFIG, build_frame, decode_frame
from ofdm.channel import simulate_channel


def main() -> None:
    p = argparse.ArgumentParser(description="Pure-Python OFDM TX/RX simulation")
    p.add_argument("--message", default="HELLO OFDM - ZedBoard AD9361")
    p.add_argument("--snr", type=float, default=25.0, help="Channel SNR in dB")
    p.add_argument("--cfo", type=float, default=1000.0, help="CFO in Hz")
    p.add_argument("--delay", type=int, default=137, help="Unknown packet delay in samples")
    p.add_argument("--no-multipath", action="store_true")
    p.add_argument("--no-plot", action="store_true")
    args = p.parse_args()

    cfg = DEFAULT_CONFIG
    payload = args.message.encode("utf-8")

    tx, meta = build_frame(payload, cfg)
    print(tx.shape,meta)
    rx = simulate_channel(
        tx,
        cfg,
        snr_db=args.snr,
        cfo_hz=args.cfo,
        delay_samples=args.delay,
        multipath=not args.no_multipath,
    )
    result = decode_frame(rx, cfg)

    print("=== OFDM simulation ===")
    print(f"FFT / CP       : {cfg.nfft} / {cfg.cp_len}")
    print(f"Data / pilots  : {len(cfg.data_k)} / {len(cfg.pilot_k)}")
    print(f"Sample rate    : {cfg.sample_rate:,} S/s")
    print(f"Frame samples  : {meta['frame_samples']}")
    print(f"Payload symbols: {meta['payload_symbols']}")
    print(f"True delay     : {args.delay} samples")
    print(f"Detected start : {result['frame_start']} samples")
    print(f"True CFO       : {args.cfo:.2f} Hz")
    print(f"Estimated CFO  : {result['cfo_hz']:.2f} Hz")
    print(f"CRC            : {'PASS' if result['crc_ok'] else 'FAIL'}")
    print(f"RX message     : {result['payload'].decode('utf-8', errors='replace')}")

    if args.no_plot:
        return

    const = result["constellation"]
    metric = result["correlation_metric"]
    h = result["channel"]

    plt.figure()
    plt.plot(np.abs(metric))
    plt.axvline(result["frame_start"], linestyle="--", label="detected start")
    plt.title("Preamble correlation / packet detection")
    plt.xlabel("Candidate start sample")
    plt.ylabel("|correlation|")
    plt.legend()
    plt.grid(True)

    plt.figure()
    plt.scatter(const.real, const.imag, s=18)
    plt.axhline(0)
    plt.axvline(0)
    plt.title("Equalized QPSK constellation")
    plt.xlabel("I")
    plt.ylabel("Q")
    plt.axis("equal")
    plt.grid(True)

    used_bins = np.mod(cfg.used_k, cfg.nfft)
    plt.figure()
    plt.stem(cfg.used_k, np.abs(h[used_bins]))
    plt.title("Estimated channel magnitude")
    plt.xlabel("Subcarrier k")
    plt.ylabel("|H[k]|")
    plt.grid(True)

    plt.show()


if __name__ == "__main__":
    main()
