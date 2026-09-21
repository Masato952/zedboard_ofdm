from __future__ import annotations

from dataclasses import dataclass
import math
import zlib

import numpy as np


@dataclass(frozen=True)
class OFDMConfig:
    nfft: int = 64
    cp_len: int = 16
    sample_rate: int = 1_000_000

    # 802.11a-like occupied subcarriers: -26..-1, +1..+26
    pilot_k: tuple[int, ...] = (-21, -7, 7, 21)
    pilot_values: tuple[complex, ...] = (1 + 0j, 1 + 0j, 1 + 0j, -1 + 0j)

    @property
    def used_k(self) -> np.ndarray:
        return np.r_[np.arange(-26, 0), np.arange(1, 27)]

    @property
    def data_k(self) -> np.ndarray:
        pilots = set(self.pilot_k)
        return np.array([k for k in self.used_k if k not in pilots], dtype=int)

    @property
    def bits_per_ofdm_symbol(self) -> int:
        # QPSK = 2 bits/subcarrier, 48 data carriers => 96 bits/symbol
        return len(self.data_k) * 2

    @property
    def samples_per_ofdm_symbol(self) -> int:
        return self.nfft + self.cp_len


DEFAULT_CONFIG = OFDMConfig()
MAGIC = b"OF"
HEADER_BYTES = 4  # MAGIC(2) + payload_len(2)
CRC_BYTES = 4


def _bin_index(k: np.ndarray | list[int] | tuple[int, ...], nfft: int) -> np.ndarray:
    """Map signed subcarrier numbers to NumPy FFT-bin indices."""
    return np.mod(np.asarray(k, dtype=int), nfft)


def bytes_to_bits(data: bytes) -> np.ndarray:
    if not data:
        return np.zeros(0, dtype=np.uint8)
    return np.unpackbits(np.frombuffer(data, dtype=np.uint8))


def bits_to_bytes(bits: np.ndarray) -> bytes:
    bits = np.asarray(bits, dtype=np.uint8)
    n = (len(bits) // 8) * 8
    if n == 0:
        return b""
    return np.packbits(bits[:n]).tobytes()


def qpsk_map(bits: np.ndarray) -> np.ndarray:
    """Gray-like quadrant mapping used consistently by this project.

    00 -> +1 + j
    01 -> +1 - j
    10 -> -1 + j
    11 -> -1 - j
    """
    bits = np.asarray(bits, dtype=np.uint8)
    if len(bits) % 2:
        raise ValueError("QPSK needs an even number of bits")
    b = bits.reshape(-1, 2).astype(np.int8)
    symbols = (1 - 2 * b[:, 0]) + 1j * (1 - 2 * b[:, 1])
    return symbols / np.sqrt(2.0)


def qpsk_demap(symbols: np.ndarray) -> np.ndarray:
    symbols = np.asarray(symbols)
    bits = np.empty(symbols.size * 2, dtype=np.uint8)
    bits[0::2] = (symbols.real < 0).astype(np.uint8)
    bits[1::2] = (symbols.imag < 0).astype(np.uint8)
    return bits


def make_training_frequency(cfg: OFDMConfig = DEFAULT_CONFIG) -> np.ndarray:
    """Create a deterministic BPSK long-training symbol in frequency domain."""
    rng = np.random.default_rng(0x9361)
    bpsk_bits = rng.integers(0, 2, len(cfg.used_k), dtype=np.uint8).astype(np.int8)
    x = np.zeros(cfg.nfft, dtype=np.complex128)
    x[_bin_index(cfg.used_k, cfg.nfft)] = 1 - 2 * bpsk_bits
    return x


def add_cp(time_symbol: np.ndarray, cp_len: int) -> np.ndarray:
    return np.concatenate([time_symbol[-cp_len:], time_symbol])


def remove_cp(symbol_with_cp: np.ndarray, cfg: OFDMConfig = DEFAULT_CONFIG) -> np.ndarray:
    return symbol_with_cp[cfg.cp_len : cfg.cp_len + cfg.nfft]


def make_training_symbol(cfg: OFDMConfig = DEFAULT_CONFIG) -> np.ndarray:
    x = make_training_frequency(cfg)
    t = np.fft.ifft(x)
    return add_cp(t, cfg.cp_len)


def make_preamble(cfg: OFDMConfig = DEFAULT_CONFIG) -> np.ndarray:
    """Two identical long-training OFDM symbols.

    Repetition lets us estimate carrier-frequency offset (CFO), while the
    known frequency-domain pattern lets us estimate the channel.
    """
    train = make_training_symbol(cfg)
    return np.concatenate([train, train])


def pack_payload(payload: bytes) -> bytes:
    if len(payload) > 65535:
        raise ValueError("Payload too large for the 16-bit length field")
    crc = zlib.crc32(payload) & 0xFFFFFFFF
    return MAGIC + len(payload).to_bytes(2, "big") + payload + crc.to_bytes(4, "big")


def unpack_payload(raw: bytes) -> tuple[bytes, bool]:
    if len(raw) < HEADER_BYTES + CRC_BYTES:
        raise ValueError("Decoded packet is too short")
    if raw[:2] != MAGIC:
        raise ValueError(f"Bad magic: expected {MAGIC!r}, got {raw[:2]!r}")

    payload_len = int.from_bytes(raw[2:4], "big")
    packet_len = HEADER_BYTES + payload_len + CRC_BYTES
    if len(raw) < packet_len:
        raise ValueError(
            f"Incomplete packet: need {packet_len} bytes, decoded only {len(raw)}"
        )

    payload = raw[HEADER_BYTES : HEADER_BYTES + payload_len]
    rx_crc = int.from_bytes(raw[HEADER_BYTES + payload_len : packet_len], "big")
    calc_crc = zlib.crc32(payload) & 0xFFFFFFFF
    return payload, rx_crc == calc_crc


def _make_payload_symbol(
    bits: np.ndarray,
    symbol_index: int,
    cfg: OFDMConfig,
) -> np.ndarray:
    x = np.zeros(cfg.nfft, dtype=np.complex128)
    x[_bin_index(cfg.data_k, cfg.nfft)] = qpsk_map(bits)

    # Fixed pilots in v0.1. They are used to remove common phase error.
    pilots = np.asarray(cfg.pilot_values, dtype=np.complex128)
    x[_bin_index(cfg.pilot_k, cfg.nfft)] = pilots

    t = np.fft.ifft(x)
    return add_cp(t, cfg.cp_len)


def build_frame(
    payload: bytes,
    cfg: OFDMConfig = DEFAULT_CONFIG,
    peak: float = 0.60,
) -> tuple[np.ndarray, dict]:
    """Build one complete complex-baseband OFDM frame.

    Frame layout:
        [training][training][QPSK OFDM payload symbols...]

    Payload bytes internally become:
        MAGIC + length + payload + CRC32
    """
    raw_packet = pack_payload(payload)
    packet_bits = bytes_to_bits(raw_packet)
    bps = cfg.bits_per_ofdm_symbol
    n_payload_symbols = math.ceil(len(packet_bits) / bps)
    pad_bits = n_payload_symbols * bps - len(packet_bits)
    if pad_bits:
        packet_bits = np.concatenate(
            [packet_bits, np.zeros(pad_bits, dtype=np.uint8)]
        )

    symbols = []
    for m in range(n_payload_symbols):
        bits = packet_bits[m * bps : (m + 1) * bps]
        symbols.append(_make_payload_symbol(bits, m, cfg))

    frame = np.concatenate([make_preamble(cfg), *symbols])

    # One global scale keeps training and payload relative amplitudes intact.
    max_abs = float(np.max(np.abs(frame)))
    if max_abs > 0:
        frame = frame * (peak / max_abs)

    meta = {
        "payload_bytes": len(payload),
        "raw_packet_bytes": len(raw_packet),
        "payload_symbols": n_payload_symbols,
        "frame_samples": len(frame),
        "pad_bits": pad_bits,
    }
    return frame.astype(np.complex64), meta


def detect_frame_start(
    rx: np.ndarray,
    cfg: OFDMConfig = DEFAULT_CONFIG,
) -> tuple[int, np.ndarray]:
    """Matched-filter packet detection against the known two-symbol preamble."""
    rx = np.asarray(rx)
    template = make_preamble(cfg)
    if len(rx) < len(template):
        raise ValueError("RX capture is shorter than the preamble")

    corr = np.correlate(rx, template, mode="valid")
    metric = np.abs(corr)
    start = int(np.argmax(metric))
    return start, metric


def estimate_cfo_from_repeated_training(
    rx_from_start: np.ndarray,
    cfg: OFDMConfig = DEFAULT_CONFIG,
) -> float:
    """Estimate CFO in Hz from phase rotation between repeated training symbols."""
    sym_len = cfg.samples_per_ofdm_symbol
    if len(rx_from_start) < 2 * sym_len:
        raise ValueError("Not enough samples for two training symbols")

    s1 = rx_from_start[cfg.cp_len : cfg.cp_len + cfg.nfft]
    second_start = sym_len
    s2 = rx_from_start[
        second_start + cfg.cp_len : second_start + cfg.cp_len + cfg.nfft
    ]

    phase = np.angle(np.vdot(s1, s2))
    rad_per_sample = phase / sym_len
    return float(rad_per_sample * cfg.sample_rate / (2 * np.pi))


def correct_cfo(
    x: np.ndarray,
    cfo_hz: float,
    cfg: OFDMConfig = DEFAULT_CONFIG,
) -> np.ndarray:
    n = np.arange(len(x))
    rot = np.exp(-1j * 2 * np.pi * cfo_hz * n / cfg.sample_rate)
    return x * rot


def estimate_channel(
    rx_from_start_cfo_corrected: np.ndarray,
    cfg: OFDMConfig = DEFAULT_CONFIG,
) -> np.ndarray:
    sym_len = cfg.samples_per_ofdm_symbol
    y_acc = np.zeros(cfg.nfft, dtype=np.complex128)

    for m in range(2):
        block = rx_from_start_cfo_corrected[m * sym_len : (m + 1) * sym_len]
        y_acc += np.fft.fft(remove_cp(block, cfg))

    y_train = y_acc / 2.0
    x_train = make_training_frequency(cfg)

    h = np.ones(cfg.nfft, dtype=np.complex128)
    used = _bin_index(cfg.used_k, cfg.nfft)
    h[used] = y_train[used] / x_train[used]
    return h


def _decode_one_payload_symbol(
    block: np.ndarray,
    h: np.ndarray,
    cfg: OFDMConfig,
) -> tuple[np.ndarray, np.ndarray]:
    y = np.fft.fft(remove_cp(block, cfg))
    eq = y / (h + 1e-12)

    # Common phase error correction using the four pilots.
    pilot_bins = _bin_index(cfg.pilot_k, cfg.nfft)
    expected_pilots = np.asarray(cfg.pilot_values, dtype=np.complex128)
    rx_pilots = eq[pilot_bins]
    cpe = np.angle(np.mean(rx_pilots * np.conj(expected_pilots)))
    eq *= np.exp(-1j * cpe)

    data_symbols = eq[_bin_index(cfg.data_k, cfg.nfft)]
    bits = qpsk_demap(data_symbols)
    return bits, data_symbols


def decode_frame(
    rx: np.ndarray,
    cfg: OFDMConfig = DEFAULT_CONFIG,
) -> dict:
    """Detect and decode the first strongest OFDM frame in an RX capture."""
    rx = np.asarray(rx, dtype=np.complex128)
    start, corr_metric = detect_frame_start(rx, cfg)
    segment = rx[start:].copy()

    cfo_hz = estimate_cfo_from_repeated_training(segment, cfg)
    segment = correct_cfo(segment, cfo_hz, cfg)
    h = estimate_channel(segment, cfg)

    preamble_len = len(make_preamble(cfg))
    sym_len = cfg.samples_per_ofdm_symbol
    available_symbols = max(0, (len(segment) - preamble_len) // sym_len)
    if available_symbols < 1:
        raise ValueError("No complete payload OFDM symbol after preamble")

    all_bits: list[np.ndarray] = []
    constellation: list[np.ndarray] = []
    expected_symbols: int | None = None

    for m in range(available_symbols):
        p0 = preamble_len + m * sym_len
        block = segment[p0 : p0 + sym_len]
        bits, data_symbols = _decode_one_payload_symbol(block, h, cfg)
        all_bits.append(bits)
        constellation.append(data_symbols)

        # The first OFDM symbol has 12 bytes (96 bits), enough to read length.
        if m == 0:
            first_bytes = bits_to_bytes(bits)
            if first_bytes[:2] != MAGIC:
                raise ValueError(
                    "Header magic was not recovered. Packet timing/CFO/SNR may be bad."
                )
            payload_len = int.from_bytes(first_bytes[2:4], "big")
            total_bytes = HEADER_BYTES + payload_len + CRC_BYTES
            total_bits = total_bytes * 8
            expected_symbols = math.ceil(total_bits / cfg.bits_per_ofdm_symbol)

        if expected_symbols is not None and len(all_bits) >= expected_symbols:
            break

    if expected_symbols is None or len(all_bits) < expected_symbols:
        raise ValueError(
            f"Capture ended early: need {expected_symbols} payload symbols, "
            f"have {len(all_bits)}"
        )

    decoded_bits = np.concatenate(all_bits[:expected_symbols])
    decoded_raw = bits_to_bytes(decoded_bits)
    payload, crc_ok = unpack_payload(decoded_raw)

    return {
        "payload": payload,
        "crc_ok": crc_ok,
        "frame_start": start,
        "cfo_hz": cfo_hz,
        "channel": h,
        "constellation": np.concatenate(constellation[:expected_symbols]),
        "correlation_metric": corr_metric,
        "payload_symbols": expected_symbols,
    }
