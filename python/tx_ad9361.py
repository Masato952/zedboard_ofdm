from __future__ import annotations

import argparse
import time

import numpy as np

from ofdm import OFDMConfig, build_frame


def main() -> None:
    p = argparse.ArgumentParser(
        description="Transmit one OFDM frame with AD9361 (single burst, not repeated)"
    )
    p.add_argument("--uri", default="ip:192.168.33.31")
    p.add_argument("--fc", type=int, default=2_400_000_000, help="TX LO in Hz")
    p.add_argument("--fs", type=int, default=1_000_000, help="Sample rate in S/s")
    p.add_argument("--gain", type=float, default=-20.0, help="TX hardware gain in dB")
    p.add_argument("--message", default="HELLO OFDM FROM AD9361")
    p.add_argument("--guard", type=int, default=512, help="Zero samples appended after each repeat")
    p.add_argument(
        "--repeat",
        type=int,
        default=1,
        help=(
            "How many back-to-back copies to send in this one burst. "
            "RX polls in fixed-size chunks and can miss a single "
            "microsecond-scale burst entirely at high --fs (its own "
            "per-chunk processing time can exceed the chunk's real-time "
            "duration); repeating the same frame a few dozen times inside "
            "one still-one-shot TX call gives it more chances to land "
            "inside a chunk RX is actually capturing."
        ),
    )
    p.add_argument(
        "--print-iq",
        action="store_true",
        help=(
            "Print the exact integer I/Q samples handed to sdr.tx(), for "
            "comparing against an FPGA ILA capture of axi_ad9361's "
            "dac_data_i0/dac_data_q0."
        ),
    )
    args = p.parse_args()

    try:
        import adi
    except ImportError as e:
        raise SystemExit("Install pyadi-iio first: pip install pyadi-iio") from e

    cfg = OFDMConfig(sample_rate=args.fs)
    frame, meta = build_frame(args.message.encode("utf-8"), cfg, peak=0.55)
    one_shot = np.concatenate([frame, np.zeros(args.guard, dtype=np.complex64)])
    waveform = np.tile(one_shot, max(1, args.repeat))

    # AD9361 DAC streaming commonly uses roughly +/- 2^14 full scale.
    iq = waveform * (2**14)

    if args.print_iq:
        n_frame = meta["frame_samples"]
        print(
            f"\n--- IQ samples about to be sent "
            f"(first {n_frame} of {len(iq)}; trailing "
            f"{len(iq) - n_frame} guard samples are all zero) ---"
        )
        print(f"{'idx':>5} {'I':>8} {'Q':>8}")
        for i in range(n_frame):
            print(f"{i:5d} {round(iq[i].real):8d} {round(iq[i].imag):8d}")
        print("--- end IQ dump ---\n")

    sdr = adi.ad9361(uri=args.uri)
    sdr.sample_rate = int(args.fs)
    sdr.tx_lo = int(args.fc)
    # Leave headroom below the sample rate: this OFDM design occupies
    # 52/64=81.25% of it already, and setting the filter exactly equal to
    # the sample rate leaves no transition-band margin (confirmed on the
    # bench to badly distort/attenuate the outer subcarriers, especially at
    # higher sample rates).
    sdr.tx_rf_bandwidth = int(min(max(args.fs * 0.95, 200_000), 56_000_000))
    sdr.tx_enabled_channels = [0]
    sdr.tx_hardwaregain_chan0 = float(args.gain)

    # One-shot burst: the hardware DMA plays this buffer through exactly
    # once, instead of looping it forever (tx_cyclic_buffer=False). This is
    # the "send when you actually have something to send" model real radios
    # use, as opposed to continuously jamming the channel with one repeated
    # frame -- see FRAME_AND_RX_PIPELINE.md for the fuller discussion.
    sdr.tx_cyclic_buffer = False

    print("=== AD9361 OFDM TX (single burst) ===")
    print(f"URI            : {args.uri}")
    print(f"LO             : {args.fc / 1e9:.6f} GHz")
    print(f"Sample rate    : {args.fs:,} S/s")
    print(f"TX gain        : {args.gain:.1f} dB")
    print(f"Frame samples  : {meta['frame_samples']}")
    print(f"Guard samples  : {args.guard}")
    print(f"Repeats        : {args.repeat}")
    print(f"Total duration : {len(iq) / args.fs * 1e3:.2f} ms")
    print(f"Message        : {args.message!r}")

    sdr.tx(iq)

    # Give the DMA time to actually drain the buffer through the DAC before
    # we tear the context down -- tx() itself only guarantees the samples
    # were handed off, not that transmission finished.
    burst_seconds = len(iq) / args.fs
    time.sleep(burst_seconds + 0.05)

    sdr.tx_destroy_buffer()
    print("Burst sent.")


if __name__ == "__main__":
    main()
