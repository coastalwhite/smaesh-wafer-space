# SPDX-FileCopyrightText: © 2025 Project Template Contributors
# SPDX-License-Identifier: Apache-2.0
"""Testbench for the bit-serial SMAesH driver, standalone.

This drives the driver's own Rx/Tx ports with no pads in the way, and carries
the functional coverage: every key size, both directions, and back-to-back
runs. chip_top_tb covers the same driver reached through the chip's pads, and
only needs one vector to show the wiring is right.

See smaesh_protocol.py for the wire format.
"""

import logging
import os
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, Timer
from cocotb_tools.runner import get_runner

from smaesh_protocol import SmaeshLink, check, load_kat

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


async def kat_encrypt(dut, keysize):
    """One encryption vector at the given key size."""
    await start_clock(dut)
    await reset(dut)

    key, plaintext, ciphertext = load_kat(f"ECBGFSbox{keysize}.rsp", limit=1)[0]
    assert len(key) * 8 == keysize

    got = await link(dut).run_block(key, plaintext)
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

    got = await link(dut).run_block(key, ciphertext, decrypt=True)
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

    smaesh = link(dut)
    for i, (key, plaintext, ciphertext) in enumerate(
        load_kat("ECBGFSbox128.rsp", limit=4)
    ):
        got = await smaesh.run_block(key, plaintext)
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
