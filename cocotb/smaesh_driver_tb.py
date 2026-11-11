# SPDX-FileCopyrightText: © 2025 Project Template Contributors
# SPDX-License-Identifier: Apache-2.0
"""Testbench for the bit-serial SMAesH driver, standalone.

This drives the driver's own Rx/Tx ports with no pads in the way, and carries
the functional coverage: both implementations (d=2 and d=3), every key size,
both directions, and runs chained without an intervening reset. chip_top_tb
covers the same driver reached through the chip's pads, and only needs one
vector to show the wiring is right.

See smaesh_protocol.py for the wire format.
"""

import itertools
import logging
import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tools.runner import get_runner

from smaesh_protocol import (
    INV_SBOX,
    SBOX,
    SmaeshLink,
    check,
    load_kat,
    sbox_rnd_bits,
)

PROJ_PATH = Path(__file__).resolve().parent
REPO_PATH = PROJ_PATH.parent

# Icarus is not an option: it cannot elaborate SMAesH's parameter style
# ("Unable to bind parameter 'd'"), and upstream only supports verilator.
sim = os.getenv("SIM", "verilator")

# Tracing is off by default. WAVES=1 writes sim_build/dump.vcd -- expect a
# few hundred MB, since it covers the whole masked core for every test.
#
# VCD rather than FST on purpose: verilator's FST writer includes <zlib.h>,
# and the devshell puts no C headers on the include path, so --trace-fst
# fails to compile there. Pass --trace-depth to narrow the dump if needed.
waves = bool(os.getenv("WAVES"))

# Flattened SMAesH tree built by `nix build .#smaesh-hdl`. The default is the
# `result` symlink that produces.
smaesh_hdl = Path(os.getenv("SMAESH_HDL", REPO_PATH / "result" / "hdl"))

hdl_toplevel = "smaesh_driver"

CLK_PERIOD_NS = 20  # 50 MHz

logger = logging.getLogger("smaesh_driver_tb")


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, "ns").start())


async def reset(dut):
    dut.Rx.value = 0
    dut.rst_n.value = 0
    await Timer(5 * CLK_PERIOD_NS, "ns")
    dut.rst_n.value = 1
    # Land on a clean edge so the bit stream below is phase-aligned.
    await RisingEdge(dut.clk)


def link(dut):
    """A SmaeshLink onto the driver's own ports."""

    def set_rx(bit):
        dut.Rx.value = bit

    def get_tx():
        return int(dut.Tx.value)

    return SmaeshLink(dut.clk, set_rx, get_tx)


def describe(nshares, keysize, decrypt):
    """Short label for one (implementation, key size, direction) combination."""
    return f"d={nshares} AES-{keysize} {'decrypt' if decrypt else 'encrypt'}"


async def run_vector(smaesh, nshares, keysize, decrypt, vector, what=None):
    """Drive one KAT vector in the given configuration and check the result.

    The same vector runs either way round: encryption feeds the plaintext and
    expects the ciphertext, decryption feeds the ciphertext and expects the
    plaintext back.
    """
    key, plaintext, ciphertext = vector
    assert len(key) * 8 == keysize

    data_in, expected = (ciphertext, plaintext) if decrypt else (plaintext, ciphertext)

    got = await smaesh.run_block(key, data_in, decrypt=decrypt, nshares=nshares)
    check(got, expected, what or describe(nshares, keysize, decrypt), key, data_in)
    logger.info(
        "%s: %s -> %s", what or describe(nshares, keysize, decrypt),
        data_in.hex(), got.to_bytes(16, "little").hex(),
    )


async def kat_single(dut, nshares, keysize, decrypt=False):
    """One vector at the given share count, key size and direction."""
    await start_clock(dut)
    await reset(dut)

    vector = load_kat(f"ECBGFSbox{keysize}.rsp", limit=1)[0]
    await run_vector(link(dut), nshares, keysize, decrypt, vector)


# One test per (implementation, key size): each selects a different set of
# counter limits in the driver -- the Din length, the Key length, and the
# 32-bit word count fed to the core.
@cocotb.test()
async def test_d2_aes128_encrypt(dut):
    await kat_single(dut, 2, 128)


@cocotb.test()
async def test_d2_aes192_encrypt(dut):
    await kat_single(dut, 2, 192)


@cocotb.test()
async def test_d2_aes256_encrypt(dut):
    await kat_single(dut, 2, 256)


@cocotb.test()
async def test_d3_aes128_encrypt(dut):
    await kat_single(dut, 3, 128)


@cocotb.test()
async def test_d3_aes192_encrypt(dut):
    """d=3 AES-192, whose key limit is 575 -- the widest Din/Key counter case.

    Along with AES-256 below this is what caught StateCtr being a bit too
    narrow: at 9 bits the limit truncated to 63 and the driver accepted 64
    key bits instead of 576.
    """
    await kat_single(dut, 3, 192)


@cocotb.test()
async def test_d3_aes256_encrypt(dut):
    """d=3 AES-256: key limit 767, and the longest frame the driver accepts."""
    await kat_single(dut, 3, 256)


@cocotb.test()
async def test_d2_aes128_decrypt(dut):
    """Decryption, which is the only thing that exercises in_key_mode_inverse."""
    await kat_single(dut, 2, 128, decrypt=True)


@cocotb.test()
async def test_d3_aes128_decrypt(dut):
    await kat_single(dut, 3, 128, decrypt=True)


# ---------------------------------------------------------------------------
# ModeSelect.SBOX: the driver's own gen_sbox pair, bypassing both smaesh_hpc
# instances. These are the only tests that reach sbox_prng and STATE_EXEC_SBOX.
# ---------------------------------------------------------------------------

# A byte whose S-box image is published, plus the fixed points and the two
# values that make the Canright basis change easy to get wrong.
SBOX_BYTES = [0x00, 0x01, 0x53, 0x7F, 0x80, 0xAB, 0xFF]


async def run_sbox_value(smaesh, nshares, value, decrypt=False, rnd=None):
    table = INV_SBOX if decrypt else SBOX
    got = await smaesh.run_sbox(value, rnd=rnd, decrypt=decrypt, nshares=nshares)
    assert got == table[value], (
        f"d={nshares} {'inverse ' if decrypt else ''}S-box({value:#04x}) "
        f"with rnd={'default' if rnd is None else hex(rnd)} "
        f"mismatch: expected {table[value]:#04x}, got {got:#04x}"
    )
    logger.info(
        "d=%d %sS-box(%#04x) -> %#04x", nshares,
        "inverse " if decrypt else "", value, got,
    )


@cocotb.test()
async def test_d2_sbox(dut):
    """Forward S-box on the d=2 instance, several bytes without a reset."""
    await start_clock(dut)
    await reset(dut)

    smaesh = link(dut)
    for value in SBOX_BYTES:
        await run_sbox_value(smaesh, 2, value)


@cocotb.test()
async def test_d3_sbox(dut):
    await start_clock(dut)
    await reset(dut)

    smaesh = link(dut)
    for value in SBOX_BYTES:
        await run_sbox_value(smaesh, 3, value)


@cocotb.test()
async def test_sbox_inverse(dut):
    """ModeDecrypt selects the inverse S-box, on both instances."""
    await start_clock(dut)
    await reset(dut)

    smaesh = link(dut)
    for nshares in (2, 3):
        for value in SBOX_BYTES:
            await run_sbox_value(smaesh, nshares, value, decrypt=True)


@cocotb.test()
async def test_sbox_exhaustive_d2(dut):
    """All 256 bytes through the d=2 S-box.

    Cheap -- an S-box run is a few hundred cycles, against tens of thousands
    for a block -- and it proves the mode is a bijection rather than just
    right on the handful of bytes above.
    """
    await start_clock(dut)
    await reset(dut)

    smaesh = link(dut)
    for value in range(256):
        await run_sbox_value(smaesh, 2, value)


@cocotb.test()
async def test_sbox_randomness_independence(dut):
    """The result must not depend on the randomness the host supplies.

    Masking changes how a value is represented, not what it is, so every
    randomness word -- including the degenerate all-zero and all-ones cases --
    has to produce the same S-box output. This is the test that would catch
    the Key field being sliced into overlapping rnd buses, or sliced past the
    bits the host actually sent.
    """
    await start_clock(dut)
    await reset(dut)

    smaesh = link(dut)
    for nshares in (2, 3):
        width = sbox_rnd_bits(nshares)
        for rnd in (0, 1, (1 << width) - 1, 0xA5A5A5A5A5A5A5A5 & ((1 << width) - 1)):
            for value in (0x00, 0x53, 0xFF):
                await run_sbox_value(smaesh, nshares, value, rnd=rnd)


@cocotb.test()
async def test_sbox_then_block(dut):
    """Interleave S-box and full-block runs without a reset.

    STATE_EXEC_RESEED is shared between the two modes but reseeds a different
    PRNG in each, and the transmit width changes from 8*d to 128*d. A run of
    either kind has to work straight after one of the other kind.
    """
    await start_clock(dut)
    await reset(dut)

    smaesh = link(dut)
    vector = load_kat("ECBGFSbox128.rsp", limit=1)[0]

    await run_sbox_value(smaesh, 2, 0x53)
    await run_vector(smaesh, 2, 128, False, vector, what="block after d=2 S-box")
    await run_sbox_value(smaesh, 3, 0x53)
    await run_vector(smaesh, 3, 128, False, vector, what="block after d=3 S-box")
    await run_sbox_value(smaesh, 2, 0xAB)


@cocotb.test()
async def test_d2_back_to_back(dut):
    """Several d=2 vectors without an intervening reset.

    Covers the driver returning to a usable STATE_DEFAULT, and the core being
    re-seeded and re-keyed cleanly for each run.
    """
    await start_clock(dut)
    await reset(dut)

    smaesh = link(dut)
    for i, vector in enumerate(load_kat("ECBGFSbox128.rsp", limit=4)):
        await run_vector(smaesh, 2, 128, False, vector, what=f"d=2 vector {i}")


@cocotb.test()
async def test_d3_back_to_back(dut):
    """The same, on the d=3 core."""
    await start_clock(dut)
    await reset(dut)

    smaesh = link(dut)
    for i, vector in enumerate(load_kat("ECBGFSbox128.rsp", limit=4)):
        await run_vector(smaesh, 3, 128, False, vector, what=f"d=3 vector {i}")


@cocotb.test()
async def test_alternating_implementations(dut):
    """Alternate d=2 and d=3 runs without a reset in between.

    This is the regression test for the exec-state handshakes. Those readys
    come from smaesh_arbitrer and do not depend on the matching valid: for a
    core that is seeded and idle, lock_key_stream is all-zero and in_key_ready
    sits high. So an idle core's ready must never be allowed to advance the
    FSM on the other core's behalf -- the driver has to select on ImplSelect,
    not OR the two together. With the OR, the first run after the *other*
    implementation has been used races through STATE_EXEC_KEY_SET without the
    selected core consuming a single key word, and then hangs forever in
    STATE_EXEC_RUN waiting on an out_valid that never comes.

    Runs 4 and 5 repeat a share count back-to-back, so a fix that merely
    alternated would not pass either.
    """
    await start_clock(dut)
    await reset(dut)

    smaesh = link(dut)
    vectors = load_kat("ECBGFSbox128.rsp", limit=2)

    for i, nshares in enumerate([2, 3, 2, 3, 3, 2]):
        vector = vectors[i % len(vectors)]
        await run_vector(smaesh, nshares, 128, False, vector, what=f"run {i} d={nshares}")


# Every (implementation, key size, direction) combination, ordered so that no
# two consecutive runs share a configuration and each step changes at least
# two of the three axes. Chained without a reset, so each run also has to cope
# with whatever state the previous configuration left the two cores in.
MIXED_SEQUENCE = [
    (2, 128, False),
    (3, 256, True),
    (2, 192, True),
    (3, 128, False),
    (2, 256, False),
    (3, 192, True),
    (3, 128, True),
    (2, 192, False),
    (3, 256, False),
    (2, 128, True),
    (3, 192, False),
    (2, 256, True),
]


@cocotb.test()
async def test_mixed_configurations(dut):
    """All 12 configurations chained, each on a different KAT vector.

    One reset at the start and then twelve runs that differ in share count,
    key size and direction, so the driver has to reconfigure every counter
    limit, both cores' handshakes and the transmit width between consecutive
    blocks. A fresh vector per run means a stale Data or Key register shows up
    as a mismatch rather than accidentally matching the previous result.
    """
    await start_clock(dut)
    await reset(dut)

    smaesh = link(dut)

    # A different vector for every run, cycling through each key size's file
    # independently so repeated key sizes do not repeat their vector.
    pools = {
        keysize: itertools.cycle(load_kat(f"ECBGFSbox{keysize}.rsp"))
        for keysize in (128, 192, 256)
    }

    seen = set()
    for i, (nshares, keysize, decrypt) in enumerate(MIXED_SEQUENCE):
        vector = next(pools[keysize])
        await run_vector(
            smaesh, nshares, keysize, decrypt, vector,
            what=f"step {i} ({describe(nshares, keysize, decrypt)})",
        )
        seen.add((nshares, keysize, decrypt))

    assert len(seen) == 12, f"expected all 12 configurations, covered {len(seen)}"


def smaesh_driver_runner():
    if not smaesh_hdl.is_dir():
        raise SystemExit(
            f"SMAesH HDL tree not found at {smaesh_hdl}.\n"
            "Build it first:  nix build .#smaesh-hdl\n"
            "or point SMAESH_HDL at an existing tree."
        )

    sources = [REPO_PATH / "src" / "smaesh_driver.sv"]
    sources += sorted(smaesh_hdl.glob("*.sv"))
    sources += sorted(smaesh_hdl.glob("*.v"))

    build_args = []
    if sim == "verilator":
        build_args = [
            "--timing",
            # SMAesH's gadget library leans on constructs Verilator warns
            # about but handles correctly; SMAesH lints it separately.
            "-Wno-fatal",
        ]
        if waves:
            # waves=True already adds --trace (VCD); this just makes packed
            # structs legible in the dump.
            build_args += ["--trace-structs"]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel=hdl_toplevel,
        defines={},
        always=True,
        includes=[smaesh_hdl],
        build_args=build_args,
        waves=waves,
    )

    runner.test(
        hdl_toplevel=hdl_toplevel,
        test_module="smaesh_driver_tb",
        plusargs=[],
        waves=waves,
    )


if __name__ == "__main__":
    smaesh_driver_runner()
