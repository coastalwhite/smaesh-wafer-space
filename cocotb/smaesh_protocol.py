# SPDX-FileCopyrightText: © 2025 Project Template Contributors
# SPDX-License-Identifier: Apache-2.0
"""The bit-serial protocol spoken by the SMAesH driver.

The driver moves one bit per clock on Rx/Tx, with no framing. A run is:

    1                       wake bit, leaves STATE_DEFAULT
    2 bits                  ModeSelect (SBox / AES128 / AES192 / AES256)
    1 bit                   ModeDecrypt
    256 bits                Din    -- the shared plaintext, always 128*d
    2*keysize bits          Key    -- the shared key
    80 bits                 Seed   -- PRNG seed

then the driver pulses Tx high for one cycle and shifts out 256 bits of
shared result. Everything is least-significant bit first.

Sharing follows SMAesH's "stridded" convention: share 0 in the low half,
share 1 in the high half, each share little-endian. An unmasked value is
therefore sent as itself with a zero second share, and the result is
recombined by XORing the two halves.

The protocol does not care where the two signals are probed, so `SmaeshLink`
takes callables rather than signal handles: smaesh_driver_tb drives the
driver's own Rx/Tx ports, and chip_top_tb drives the same exchange through
the chip's pads.
"""

import re
from pathlib import Path

from cocotb.triggers import FallingEdge, RisingEdge

REPO_PATH = Path(__file__).resolve().parent.parent

# Width of the shared data bus: 128 bits of AES state times d=2 shares.
SHARES_BITS = 256

# Any value; the core only needs the PRNG seeded before it will accept a key.
SEED = 0xDEADBEEFDEADBEEF


class ModeSelect:
    SBOX = 0b00
    AES128 = 0b01
    AES192 = 0b10
    AES256 = 0b11


class ModeDecrypt:
    ENCRYPT = 0b0
    DECRYPT = 0b1


MODE_FOR_KEYSIZE = {
    128: ModeSelect.AES128,
    192: ModeSelect.AES192,
    256: ModeSelect.AES256,
}


def load_kat(filename, limit=None):
    """Parse NIST ECB vectors out of one of SMAesH's .rsp files.

    Returns (key, plaintext, ciphertext) byte strings, in file order. Only the
    [ENCRYPT] section is read -- the files repeat each vector under [DECRYPT]
    with plaintext and ciphertext swapped.
    """
    text = (REPO_PATH / "ip" / "SMAesH" / "func_tests" / "KAT" / filename).read_text()
    text = text.split("[DECRYPT]")[0]

    cases = [
        (bytes.fromhex(k), bytes.fromhex(p), bytes.fromhex(c))
        for k, p, c in re.findall(
            r"KEY = ([0-9A-Fa-f]+)\s*\n"
            r"PLAINTEXT = ([0-9A-Fa-f]+)\s*\n"
            r"CIPHERTEXT = ([0-9A-Fa-f]+)",
            text,
        )
    ]
    assert cases, f"no vectors parsed out of {filename}"
    return cases[:limit] if limit else cases


def share_unmasked(value_bytes):
    """Encode an unmasked value as a d=2 sharing: the value, then a zero share."""
    return int.from_bytes(value_bytes + bytes(len(value_bytes)), "little")


def recombine(shared: int, nbytes=16) -> int:
    """XOR the two shares of a stridded d=2 sharing back together."""
    mask = (1 << (8 * nbytes)) - 1
    return (shared & mask) ^ ((shared >> (8 * nbytes)) & mask)


def check(got, expected_bytes, what, key, data_in):
    expected = int.from_bytes(expected_bytes, "little")
    assert got == expected, (
        f"{what} mismatch\n"
        f"  key      {key.hex()}\n"
        f"  input    {data_in.hex()}\n"
        f"  expected {expected.to_bytes(16, 'little').hex()}\n"
        f"  got      {got.to_bytes(16, 'little').hex()}"
    )


class SmaeshLink:
    """One end of the driver's bit-serial link.

    `set_rx(bit)` drives Rx and `get_tx()` samples Tx; both are supplied by
    the testbench so that the same exchange works against the driver's ports
    or against the chip's pads.
    """

    def __init__(self, clk, set_rx, get_tx):
        self.clk = clk
        self._set_rx = set_rx
        self._get_tx = get_tx

    def idle(self):
        """Park the line low, which is what the driver treats as 'no request'."""
        self._set_rx(0)

    async def send_bits(self, value: int, nbits: int):
        """Shift `value` in on Rx, most-significant bit first.

        MSB-first is what makes the driver's receive registers plain left-shift
        registers: a bit arriving at time t lands at index nbits-1-t, so
        value[j] always ends up at register bit j regardless of how many bits
        this particular field carries. That matters because the field widths
        vary with key size, and the driver reads the key from bit 0 upwards.

        Rx is written just after an edge and sampled on the next one, which is
        the edge this coroutine returns on.
        """
        for i in range(nbits):
            self._set_rx((value >> (nbits - 1 - i)) & 1)
            await RisingEdge(self.clk)

    async def recv_result(self, timeout_cycles=20_000) -> int:
        """Wait for the Tx start pulse, then shift out SHARES_BITS of result.

        Tx is combinational on State/StateCtr, so it is sampled mid-cycle on
        the falling edge rather than racing the posedge that changes it.
        """
        for _ in range(timeout_cycles):
            await FallingEdge(self.clk)
            if self._get_tx() == 1:
                break
        else:
            raise AssertionError(
                f"no Tx start pulse within {timeout_cycles} cycles -- the driver "
                "never reached STATE_TX_START"
            )

        # That pulse was STATE_TX_START; the next cycle carries the top bit.
        # Most-significant bit first, matching send_bits.
        result = 0
        for _ in range(SHARES_BITS):
            await FallingEdge(self.clk)
            result = (result << 1) | int(self._get_tx())
        return result

    async def run_block(self, key, plaintext, decrypt=False) -> int:
        """Drive one full encryption/decryption and return the recombined result."""
        keysize = len(key) * 8
        mode = MODE_FOR_KEYSIZE[keysize]

        # Wake the FSM out of STATE_DEFAULT.
        await self.send_bits(1, 1)

        await self.send_bits(mode, 2)
        await self.send_bits(
            ModeDecrypt.DECRYPT if decrypt else ModeDecrypt.ENCRYPT, 1
        )
        await self.send_bits(share_unmasked(plaintext), SHARES_BITS)
        await self.send_bits(share_unmasked(key), 2 * keysize)
        await self.send_bits(SEED, 80)

        # Idle the line while the core reseeds, loads the key and runs.
        self.idle()

        result = recombine(await self.recv_result())

        # recv_result returns mid-cycle on the last transmitted bit, and it is
        # the *next* rising edge that leaves STATE_TX_SEND. Driving a wake bit
        # before then would spend it in a state that ignores Rx, so settle into
        # STATE_DEFAULT with the line idle before returning.
        self.idle()
        await RisingEdge(self.clk)
        await RisingEdge(self.clk)

        return result
