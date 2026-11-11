# SPDX-FileCopyrightText: © 2025 Project Template Contributors
# SPDX-License-Identifier: Apache-2.0
"""The bit-serial protocol spoken by the SMAesH driver.

The driver moves one bit per clock on Rx/Tx, with no framing. A run is:

    1                       wake bit, leaves STATE_DEFAULT
    1 bit                   ImplSelect (M2 / M3)
    2 bits                  ModeSelect (SBox / AES128 / AES192 / AES256)
    1 bit                   ModeDecrypt
    128*d bits              Din    -- the shared plaintext
    d*keysize bits          Key    -- the shared key
    80 bits                 Seed   -- PRNG seed

then the driver pulses Tx high for one cycle and shifts out 128*d bits of
shared result. Everything is least-significant bit first.

ModeSelect.SBOX is a shorter frame over one byte instead of a block:

    1                       wake bit
    1 bit                   ImplSelect
    2 bits                  ModeSelect = SBOX
    1 bit                   ModeDecrypt
    8*d bits                Din    -- the shared input byte
    18*d*(d-1) bits         Rnd    -- gadget randomness, in the Key field
                                      (36 bits at d=2, 108 at d=3)

and 8*d bits of shared result. There is no Seed field: the S-box path has no
PRNG, the host supplies its randomness directly, so the driver leaves the
receive path as soon as the Rnd field is in. It evaluates a single masked
S-box through the driver's own gen_sbox pair rather than through either
smaesh_hpc, and ModeDecrypt picks the inverse S-box.

`d` is the number of shares, selected by the ImplSelect bit: the driver
instantiates one smaesh_hpc at d=2 and one at d=3, and the bit picks which
one the run goes through. It also sets every field width above, so the whole
frame length depends on it -- see `nshares` throughout this module.

Sharing follows SMAesH's "stridded" convention: share i occupies the i'th
128-bit slice, each share little-endian. An unmasked value is therefore sent
as itself with the remaining d-1 shares zero, and the result is recombined by
XORing all d slices together.

The protocol does not care where the two signals are probed, so `SmaeshLink`
takes callables rather than signal handles: smaesh_driver_tb drives the
driver's own Rx/Tx ports, and chip_top_tb drives the same exchange through
the chip's pads.
"""

import re
from pathlib import Path

from cocotb.triggers import FallingEdge, RisingEdge

REPO_PATH = Path(__file__).resolve().parent.parent

# Width of the unshared AES state, in bits. The shared bus is this times the
# number of shares.
STATE_BITS = 128

# Share counts the driver implements, i.e. the legal values of `nshares`.
NSHARES = (2, 3)

# Any value; the core only needs the PRNG seeded before it will accept a key.
SEED = 0xDEADBEEFDEADBEEF


class Implementation:
    """The ImplSelect bit: which smaesh_hpc instance the run goes through."""

    M2 = 0b0
    M3 = 0b1


IMPL_FOR_NSHARES = {2: Implementation.M2, 3: Implementation.M3}


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


def _gf_mul(a, b):
    """Multiply in GF(2^8) modulo the AES polynomial x^8+x^4+x^3+x+1."""
    out = 0
    for _ in range(8):
        if b & 1:
            out ^= a
        b >>= 1
        a <<= 1
        if a & 0x100:
            a ^= 0x11B
    return out


def _aes_sbox_table():
    """Build the AES S-box: inversion in GF(2^8) then the affine map.

    Derived instead of transcribed so there is nothing to typo, and
    spot-checked against three published entries below.
    """
    inverse = [0] * 256
    for a in range(1, 256):
        for b in range(1, 256):
            if _gf_mul(a, b) == 1:
                inverse[a] = b
                break

    def rotl(x, n):
        return ((x << n) | (x >> (8 - n))) & 0xFF

    table = []
    for a in range(256):
        x = inverse[a]
        table.append(x ^ rotl(x, 1) ^ rotl(x, 2) ^ rotl(x, 3) ^ rotl(x, 4) ^ 0x63)
    return table


SBOX = _aes_sbox_table()
INV_SBOX = [0] * 256
for _i, _v in enumerate(SBOX):
    INV_SBOX[_v] = _i

assert (SBOX[0x00], SBOX[0x01], SBOX[0x53]) == (0x63, 0x7C, 0xED), "S-box derivation"
assert sorted(SBOX) == list(range(256)), "S-box must be a permutation"


def sbox_rnd_bits(nshares):
    """Randomness one S-box consumes, 18*d*(d-1) -- 36 at d=2, 108 at d=3.

    The sum of gen_sbox's four rnd_bus widths; see the localparams in
    src/smaesh_driver.sv, which mirror canright_aes_sbox_dual.vh.
    """
    return 18 * nshares * (nshares - 1)


# Arbitrary non-zero randomness for the S-box mode. The result must not depend
# on it -- masking only changes how the value is represented -- so the tests
# use this by default and check a couple of other values give the same answer.
DEFAULT_SBOX_RND = 0x2D9F4E7B1C6A3058F7B2E49D5C1A8306


def default_sbox_rnd(nshares):
    return DEFAULT_SBOX_RND & ((1 << sbox_rnd_bits(nshares)) - 1)


def shared_bits(nshares, width=STATE_BITS):
    """Width of a `width`-bit value once shared `nshares` ways."""
    return width * nshares


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


def share_unmasked(value_bytes, nshares):
    """Encode an unmasked value as a `nshares`-way sharing.

    The value goes in share 0 and the remaining shares are zero, which
    recombines to the value itself. The core re-randomises the sharing
    internally from the PRNG, so the output shares are never trivial even
    though the input ones are.
    """
    pad = bytes(len(value_bytes) * (nshares - 1))
    return int.from_bytes(value_bytes + pad, "little")


def recombine(shared: int, nshares, nbytes=16) -> int:
    """XOR the `nshares` slices of a stridded sharing back together."""
    mask = (1 << (8 * nbytes)) - 1
    out = 0
    for i in range(nshares):
        out ^= (shared >> (8 * nbytes * i)) & mask
    return out


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
        vary with key size and share count, and the driver reads the key from
        bit 0 upwards.

        Rx is written just after an edge and sampled on the next one, which is
        the edge this coroutine returns on.
        """
        for i in range(nbits):
            self._set_rx((value >> (nbits - 1 - i)) & 1)
            await RisingEdge(self.clk)

    async def recv_result(self, nbits: int, timeout_cycles=20_000) -> int:
        """Wait for the Tx start pulse, then shift out `nbits` of result.

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
        for _ in range(nbits):
            await FallingEdge(self.clk)
            result = (result << 1) | int(self._get_tx())
        return result

    async def run_sbox(self, value: int, rnd=None, decrypt=False, nshares=2) -> int:
        """Drive one standalone masked S-box evaluation and return the byte.

        `rnd` is the gadget randomness, which the host supplies rather than a
        PRNG; it defaults to `default_sbox_rnd(nshares)`. Passing 0 runs the
        gadgets with no randomness at all, which is useful as a known-answer
        check and useless as a masked implementation.
        """
        assert nshares in NSHARES, f"nshares must be one of {NSHARES}, got {nshares}"
        assert 0 <= value <= 0xFF, f"value must be a byte, got {value:#x}"

        byte_bits = shared_bits(nshares, 8)
        rnd_bits = sbox_rnd_bits(nshares)
        if rnd is None:
            rnd = default_sbox_rnd(nshares)
        assert 0 <= rnd < (1 << rnd_bits), (
            f"rnd must fit {rnd_bits} bits at d={nshares}, got {rnd:#x}"
        )

        await self.send_bits(1, 1)

        await self.send_bits(IMPL_FOR_NSHARES[nshares], 1)
        await self.send_bits(ModeSelect.SBOX, 2)
        await self.send_bits(
            ModeDecrypt.DECRYPT if decrypt else ModeDecrypt.ENCRYPT, 1
        )
        await self.send_bits(share_unmasked(bytes([value]), nshares), byte_bits)
        # The Key field carries the randomness in this mode, and there is no
        # Seed field -- the driver starts computing as soon as this is in.
        await self.send_bits(rnd, rnd_bits)

        self.idle()

        result = recombine(await self.recv_result(byte_bits), nshares, nbytes=1)

        self.idle()
        await RisingEdge(self.clk)
        await RisingEdge(self.clk)

        return result

    async def run_block(self, key, plaintext, decrypt=False, nshares=2) -> int:
        """Drive one full encryption/decryption and return the recombined result.

        `nshares` picks the implementation (2 -> M2, 3 -> M3) and so sets the
        width of the data, key and result fields.
        """
        assert nshares in NSHARES, f"nshares must be one of {NSHARES}, got {nshares}"

        keysize = len(key) * 8
        mode = MODE_FOR_KEYSIZE[keysize]
        din_bits = shared_bits(nshares)

        # Wake the FSM out of STATE_DEFAULT.
        await self.send_bits(1, 1)

        await self.send_bits(IMPL_FOR_NSHARES[nshares], 1)
        await self.send_bits(mode, 2)
        await self.send_bits(
            ModeDecrypt.DECRYPT if decrypt else ModeDecrypt.ENCRYPT, 1
        )
        await self.send_bits(share_unmasked(plaintext, nshares), din_bits)
        await self.send_bits(
            share_unmasked(key, nshares), shared_bits(nshares, keysize)
        )
        await self.send_bits(SEED, 80)

        # Idle the line while the core reseeds, loads the key and runs.
        self.idle()

        result = recombine(await self.recv_result(din_bits), nshares)

        # recv_result returns mid-cycle on the last transmitted bit, and it is
        # the *next* rising edge that leaves STATE_TX_SEND. Driving a wake bit
        # before then would spend it in a state that ignores Rx, so settle into
        # STATE_DEFAULT with the line idle before returning.
        self.idle()
        await RisingEdge(self.clk)
        await RisingEdge(self.clk)

        return result
