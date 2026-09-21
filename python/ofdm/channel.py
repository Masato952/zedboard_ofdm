from __future__ import annotations

import numpy as np

from .core import DEFAULT_CONFIG, OFDMConfig


def add_awgn(x: np.ndarray, snr_db: float, rng: np.random.Generator) -> np.ndarray:
    power = float(np.mean(np.abs(x) ** 2))
    if power == 0:
        return x.copy()
    noise_power = power / (10 ** (snr_db / 10.0))
    sigma = np.sqrt(noise_power / 2.0)
    noise = sigma * (rng.standard_normal(len(x)) + 1j * rng.standard_normal(len(x)))
    return x + noise


def simulate_channel(
    tx: np.ndarray,
    cfg: OFDMConfig = DEFAULT_CONFIG,
    snr_db: float = 25.0,
    cfo_hz: float = 1000.0,
    delay_samples: int = 137,
    multipath: bool = True,
    seed: int = 20260915,
) -> np.ndarray:
    """A simple teaching channel: delay + multipath + CFO + AWGN."""
    rng = np.random.default_rng(seed)

    if multipath:
        # Max excess delay is 4 samples, safely shorter than CP=16.
        taps = np.array(
            [
                1.0 + 0j,
                0j,
                0.25 * np.exp(1j * 0.60),
                0j,
                0.12 * np.exp(-1j * 1.00),
            ],
            dtype=np.complex128,
        )
        y = np.convolve(tx, taps)
    else:
        y = np.asarray(tx, dtype=np.complex128).copy()

    n = np.arange(len(y))
    y *= np.exp(1j * 2 * np.pi * cfo_hz * n / cfg.sample_rate)
    y = add_awgn(y, snr_db, rng)

    # Prefix/suffix noise makes the receiver find the packet instead of assuming index 0.
    signal_rms = np.sqrt(np.mean(np.abs(y) ** 2))
    noise_rms = signal_rms / (10 ** (snr_db / 20.0))
    prefix = noise_rms * (
        rng.standard_normal(delay_samples) + 1j * rng.standard_normal(delay_samples)
    ) / np.sqrt(2)
    suffix_len = 256
    suffix = noise_rms * (
        rng.standard_normal(suffix_len) + 1j * rng.standard_normal(suffix_len)
    ) / np.sqrt(2)

    return np.concatenate([prefix, y, suffix]).astype(np.complex64)
