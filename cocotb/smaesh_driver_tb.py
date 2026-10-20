# SPDX-FileCopyrightText: © 2025 Project Template Contributors
# SPDX-License-Identifier: Apache-2.0
"""Testbench for the bit-serial SMAesH driver.

The driver speaks one bit per clock on Rx/Tx, with no framing. A run is:

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
"""

import logging
import os
import re
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import FallingEdge, RisingEdge, Timer
from cocotb_tools.runner import get_runner

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

# Any value; the core only needs the PRNG seeded before it will accept a key.
SEED = 0xDEADBEEFDEADBEEF

# Width of the shared data bus: 128 bits of AES state times d=2 shares.
SHARES_BITS = 256


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


async def start_clock(dut):
    cocotb.start_soon(Clock(dut.clk, CLK_PERIOD_NS, "ns").start())


async def reset(dut):
    dut.Rx.value = 0
    dut.rst_n.value = 0
    await Timer(5 * CLK_PERIOD_NS, "ns")
    dut.rst_n.value = 1
    # Land on a clean edge so the bit stream below is phase-aligned.
    await RisingEdge(dut.clk)


async def send_bits(dut, value: int, nbits: int):
    """Shift `value` in on Rx, least-significant bit first.

    Rx is written just after an edge and sampled on the next one, which is the
    edge this coroutine returns on.
    """
    for i in range(nbits):
        dut.Rx.value = (value >> i) & 1
        await RisingEdge(dut.clk)


async def recv_result(dut, timeout_cycles=10_000) -> int:
    """Wait for the Tx start pulse, then shift out SHARES_BITS of result.

    Tx is combinational on State/StateCtr, so it is sampled mid-cycle on the
    falling edge rather than racing the posedge that changes it.
    """
    for _ in range(timeout_cycles):
        await FallingEdge(dut.clk)
        if dut.Tx.value == 1:
            break
    else:
        raise AssertionError(
            f"no Tx start pulse within {timeout_cycles} cycles -- the driver "
            "never reached STATE_TX_START"
        )

    # That pulse was STATE_TX_START; the next cycle carries result bit 0.
    result = 0
    for i in range(SHARES_BITS):
        await FallingEdge(dut.clk)
        result |= int(dut.Tx.value) << i
    return result


async def run_block(dut, key, plaintext, decrypt=False):
    """Drive one full encryption/decryption and return the recombined result."""
    keysize = len(key) * 8
    mode = MODE_FOR_KEYSIZE[keysize]

    # Wake the FSM out of STATE_DEFAULT.
    await send_bits(dut, 1, 1)

    await send_bits(dut, mode, 2)
    await send_bits(dut, ModeDecrypt.DECRYPT if decrypt else ModeDecrypt.ENCRYPT, 1)
    await send_bits(dut, share_unmasked(plaintext), SHARES_BITS)
    await send_bits(dut, share_unmasked(key), 2 * keysize)
    await send_bits(dut, SEED, 80)

    # Idle the line while the core reseeds, loads the key and runs.
    dut.Rx.value = 0

    result = await recv_result(dut)
    result = recombine(result)

    # recv_result returns mid-cycle on the last transmitted bit, and it is the
    # *next* rising edge that leaves STATE_TX_SEND. Driving a wake bit before
    # then would spend it in a state that ignores Rx, so settle into
    # STATE_DEFAULT with the line idle before returning.
    dut.Rx.value = 0
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

    return result


def check(got, expected_bytes, what, key, data_in):
    expected = int.from_bytes(expected_bytes, "little")
    assert got == expected, (
        f"{what} mismatch\n"
        f"  key      {key.hex()}\n"
        f"  input    {data_in.hex()}\n"
        f"  expected {expected.to_bytes(16, 'little').hex()}\n"
        f"  got      {got.to_bytes(16, 'little').hex()}"
    )


async def kat_encrypt(dut, keysize):
    """One encryption vector at the given key size."""
    await start_clock(dut)
    await reset(dut)

    key, plaintext, ciphertext = load_kat(f"ECBGFSbox{keysize}.rsp", limit=1)[0]
    assert len(key) * 8 == keysize

    got = await run_block(dut, key, plaintext)
    check(got, ciphertext, f"AES-{keysize} ciphertext", key, plaintext)
    logging.getLogger("smaesh_driver_tb").info(
        "AES-%d %s -> %s", keysize, plaintext.hex(), got.to_bytes(16, "little").hex()
    )


# One test per key size: each selects a different set of counter limits in the
# driver (Key length, and the 32-bit word count fed to the core).
@cocotb.test()
async def test_aes128_encrypt(dut):
    await kat_encrypt(dut, 128)


@cocotb.test()
async def test_aes192_encrypt(dut):
    await kat_encrypt(dut, 192)


@cocotb.test()
async def test_aes256_encrypt(dut):
    await kat_encrypt(dut, 256)


@cocotb.test()
async def test_aes128_decrypt(dut):
    """Decryption, which is the only thing that exercises in_key_mode_inverse.

    The same vectors run backwards: feed the ciphertext, expect the plaintext.
    """
    await start_clock(dut)
    await reset(dut)

    key, plaintext, ciphertext = load_kat("ECBGFSbox128.rsp", limit=1)[0]

    got = await run_block(dut, key, ciphertext, decrypt=True)
    check(got, plaintext, "AES-128 plaintext", key, ciphertext)


@cocotb.test()
async def test_back_to_back(dut):
    """Several vectors without an intervening reset.

    Covers the driver returning to a usable STATE_DEFAULT, and the core being
    re-seeded and re-keyed cleanly for each run.
    """
    logger = logging.getLogger("smaesh_driver_tb")

    await start_clock(dut)
    await reset(dut)

    for i, (key, plaintext, ciphertext) in enumerate(
        load_kat("ECBGFSbox128.rsp", limit=4)
    ):
        got = await run_block(dut, key, plaintext)
        check(got, ciphertext, f"vector {i}", key, plaintext)
        logger.info("vector %d ok", i)


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
