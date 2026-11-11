# SPDX-FileCopyrightText: © 2025 Project Template Contributors
# SPDX-License-Identifier: Apache-2.0

import os
import logging
from pathlib import Path

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import Timer, RisingEdge, ClockCycles
from cocotb_tools.runner import get_runner

from smaesh_protocol import SmaeshLink, check, load_kat

proj_path = Path(__file__).resolve().parent
repo_path = proj_path.parent

sim = os.getenv("SIM", "icarus")
gl = os.getenv("GL", False)
pdk_root = os.getenv("PDK_ROOT", repo_path / "gf180mcu")
pdk = os.getenv("PDK", "gf180mcuD")
scl = os.getenv("SCL", "gf180mcu_fd_sc_mcu7t5v0")
pad = os.getenv("PAD", "gf180mcu_fd_io")
slot = os.getenv("SLOT", "1x1")

# Flattened SMAesH tree built by `nix build .#smaesh-hdl`; the `result`
# symlink is what that produces. Only needed for an RTL run -- a gate-level
# run reads the synthesised netlist instead.
smaesh_hdl = Path(os.getenv("SMAESH_HDL", repo_path / "result" / "hdl"))

hdl_toplevel = "chip_top"

# Pad assignment, mirroring the localparams in src/chip_core.sv.
SMAESH_RX_PAD = 0  # index into input_PAD
SMAESH_TX_PAD = 0  # index into bidir_PAD
SMAESH_TRIGGER_PAD = 1  # index into bidir_PAD
SMAESH_BIDIR_PADS = 2  # bidir pads taken off the counter


async def set_defaults(dut):
    dut.input_PAD.value = 0

async def enable_power(dut):
    dut.VDD.value = 1
    dut.VSS.value = 0

async def start_clock(clock, freq=50):
    """Start the clock @ freq MHz"""
    c = Clock(clock, 1 / freq * 1000, "ns")
    cocotb.start_soon(c.start())


async def reset(reset, active_low=True, time_ns=1000):
    """Reset dut"""
    cocotb.log.info("Reset asserted...")

    reset.value = not active_low
    await Timer(time_ns, "ns")
    reset.value = active_low

    cocotb.log.info("Reset deasserted.")


async def start_up(dut):
    """Startup sequence"""
    await set_defaults(dut)
    if gl:
        await enable_power(dut)
    await start_clock(dut.clk_PAD)
    await reset(dut.rst_n_PAD)


@cocotb.test()
async def test_counter(dut):
    """Run the counter test"""

    # Create a logger for this testbench
    logger = logging.getLogger("my_testbench")

    logger.info("Startup sequence...")

    # Start up
    await start_up(dut)

    logger.info("Running the test...")

    # Wait for some time...
    await ClockCycles(dut.clk_PAD, 10)

    # Please note that cocotb cannpt write to individual bits of a vector.
    # If you need to write to individual bits, you can separate e.g. the
    # bidir_PAD vector into individual bits through a tb wrapper.
    # Even better, use individual pad names for each bit.

    # Start the counter by setting all inputs to 1
    dut.input_PAD.value = -1

    # Wait for a number of clock cycles
    await ClockCycles(dut.clk_PAD, 100)

    # The counter sits above the bidir pads the SMAesH driver took, so shift
    # them off before comparing. Driving input_PAD high also drives Rx, which
    # wakes the driver -- it spends the next ~850 cycles shifting bits in and
    # leaves Tx/Trigger low throughout, so those two pads read 0 here.
    assert (int(dut.bidir_PAD.value) >> SMAESH_BIDIR_PADS) == 100 - 1

    logger.info("Done!")


def smaesh_link(dut):
    """A SmaeshLink onto the chip's pads.

    Rx is one bit of the input_PAD vector and cocotb can only assign the
    vector as a whole, so the other input pads are held low -- which also
    keeps the counter above from running during the exchange.
    """

    def set_rx(bit):
        dut.input_PAD.value = bit << SMAESH_RX_PAD

    def get_tx():
        return dut.bidir_PAD.value[SMAESH_TX_PAD]

    return SmaeshLink(dut.clk_PAD, set_rx, get_tx)


@cocotb.test()
async def test_smaesh_aes128(dut):
    """One AES-128 vector driven through the pads.

    This is the chip-level wiring check: that Rx reaches the driver from an
    input pad, that Tx comes back out on a bidir pad, and that Trigger pulses.
    The functional coverage (every key size, decryption, back-to-back runs)
    lives in smaesh_driver_tb, which drives the driver directly.
    """
    logger = logging.getLogger("chip_top_tb")

    await start_up(dut)
    await RisingEdge(dut.clk_PAD)

    key, plaintext, ciphertext = load_kat("ECBGFSbox128.rsp", limit=1)[0]

    # Watch Trigger for the duration: the driver raises it for the cycle in
    # which the masked core latches its input, and a side-channel setup has
    # nothing to arm the scope on if it never fires.
    trigger_seen = False

    async def watch_trigger():
        nonlocal trigger_seen
        while True:
            await RisingEdge(dut.clk_PAD)
            if dut.bidir_PAD.value[SMAESH_TRIGGER_PAD] == 1:
                trigger_seen = True

    watcher = cocotb.start_soon(watch_trigger())

    got = await smaesh_link(dut).run_block(key, plaintext)
    watcher.cancel()

    check(got, ciphertext, "AES-128 ciphertext through the pads", key, plaintext)
    assert trigger_seen, "Trigger never pulsed on bidir_PAD[%d]" % SMAESH_TRIGGER_PAD

    logger.info(
        "AES-128 through pads: %s -> %s",
        plaintext.hex(),
        got.to_bytes(16, "little").hex(),
    )


def chip_top_runner():

    sources = []
    defines = {f"SLOT_{slot.upper()}": True}
    includes = [proj_path / "../src/"]

    # Set the LibreLane PDK/SCL/PAD defines
    defines[f"PDK_{pdk.replace('-','_')}"] = True
    defines[f"SCL_{scl}"] = True
    defines[f"PAD_{pad}"] = True

    if gl:
        # SCL models
        sources.append(Path(pdk_root) / pdk / "libs.ref" / scl / "verilog" / f"{scl}.v")
        if scl != "gf180mcu_as_sc_mcu7t3v3":
            sources.append(Path(pdk_root) / pdk / "libs.ref" / scl / "verilog" / "primitives.v")

        # We use the powered netlist
        sources.append(proj_path / f"../final/pnl/{hdl_toplevel}.pnl.v")

        defines.update({"FUNCTIONAL": True, "USE_POWER_PINS": True})
    else:
        if not smaesh_hdl.is_dir():
            raise SystemExit(
                f"SMAesH HDL tree not found at {smaesh_hdl}.\n"
                "chip_core instantiates smaesh_driver, which needs it.\n"
                "Build it first:  nix build .#smaesh-hdl\n"
                "or point SMAESH_HDL at an existing tree."
            )

        sources.append(proj_path / "../src/chip_top.sv")
        sources.append(proj_path / "../src/chip_core.sv")

        # The SMAesH driver and the masked core it wraps.
        sources.append(proj_path / "../src/smaesh_driver.sv")
        sources += sorted(smaesh_hdl.glob("*.sv"))
        sources += sorted(smaesh_hdl.glob("*.v"))
        includes.append(proj_path / "../src")
        includes.append(smaesh_hdl)

    sources += [
        # IO pad models
        Path(pdk_root) / pdk / f"libs.ref/{pad}/verilog/{pad}.v",

        # Custom IP
        proj_path / "../ip/gf180mcu_ws_ip__logo/vh/gf180mcu_ws_ip__logo.v",
        proj_path / "../ip/gf180mcu_ws_ip__marker/vh/gf180mcu_ws_ip__marker.v",
        proj_path / "../ip/gf180mcu_ws_ip__qrcode_id/vh/gf180mcu_ws_ip__qrcode_id.v",
        proj_path / "../ip/gf180mcu_ws_ip__shuttle_id/vh/gf180mcu_ws_ip__shuttle_id.v",
        proj_path / "../ip/gf180mcu_ws_ip__project_id/vh/gf180mcu_ws_ip__project_id.v",

    ]

    # Tracing is off by default: with the masked core in the design a full
    # dump runs to hundreds of MB. WAVES=1 turns it back on.
    waves = bool(os.getenv("WAVES"))

    build_args = []

    if sim == "icarus":
        # For debugging
        # build_args = ["-Winfloop", "-pfileline=1"]
        pass

    if sim == "verilator":
        build_args = ["--timing", "-Wno-fatal"]
        if waves:
            build_args += ["--trace-structs"]

    runner = get_runner(sim)
    runner.build(
        sources=sources,
        hdl_toplevel=hdl_toplevel,
        defines=defines,
        always=True,
        includes=includes,
        build_args=build_args,
        waves=waves,
    )

    plusargs = []

    runner.test(
        hdl_toplevel=hdl_toplevel,
        test_module="chip_top_tb",
        plusargs=plusargs,
        waves=waves,
    )


if __name__ == "__main__":
    chip_top_runner()
