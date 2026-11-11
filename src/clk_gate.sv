// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

// Clock gate: `gclk` follows `clk` while `en` (or `test_en`) is high, and is
// held low otherwise.
//
// `en` is sampled during the *low* phase of `clk` and held through the high
// phase, so `gclk` is always either a full-width `clk` pulse or no pulse at
// all. That is the entire point of the module. The enables in this design come
// from posedge-`clk` registers (ImplSelect), so they change while `clk` is
// still high; a plain `gclk = clk & en` would chop the pulse that is in flight
// down to the enable path delay, well under the 0.96 ns min_pulse_width_high
// that gf180mcu_fd_sc_mcu7t5v0__dffq_1 needs at ss_125C_4v50. The gated flops
// would then capture inconsistently, which for a masked core means some shares
// update and others do not -- the clock-glitch fault model, built in by
// accident.
//
// Note that a bare AND would *simulate* fine. Verilog's delta-cycle ordering
// turns the runt pulse into a zero-width glitch that no `always @(posedge)`
// reacts to, so the failure only ever shows up in silicon. That asymmetry is
// why this module exists rather than an `assign`.
//
// Which implementation is used:
//
//   - LibreLane (which defines `__pnr__`) with an SCL that has an integrated
//     clock gate: the ICG cell is instantiated directly. STA then checks `en`
//     against CLK through the cell's setup_rising/hold_rising arcs, and CTS
//     recognises it as a clock gate rather than as random combinational logic
//     in the clock path.
//   - Everything else -- RTL simulation under any simulator, with or without
//     the SCL_* defines the flow and cocotb both set -- gets the behavioural
//     latch below, which matches the cell's state table exactly.
//
// The behavioural path is deliberately *not* a synthesis fallback: it infers a
// negative-level-sensitive latch, and gf180mcu's latch_map.v only maps
// $_DLATCH_P_/$_DLATCH_PN0_/$_DLATCH_PN1_, so $_DLATCH_N_ would survive
// dfflibmap and abc unmapped. Reading this module in the PnR flow without a
// known ICG therefore fails at elaboration instead, with the message below.
// gf180mcu_as_sc_mcu7t3v3 is that case: it has no icg* cells at all (and no
// latch_map.v either), so it needs a hand-built gate from its dlxtn_2 + and2_2
// before it can be used here.
//
// Gate-level simulation never sees this module: the netlist is flat and
// carries the cell itself.
//
// Define CLK_GATE_FORCE_BEHAVIORAL to take the behavioural path everywhere,
// which is how the two are diffed against each other.

`ifndef CLK_GATE_FORCE_BEHAVIORAL
`ifdef __pnr__
    // Both fd SCLs spell the cell the same way: icgtp_{1,2,4}, ports
    // (TE, E, CLK, Q), "latch_posedge_precontrol" -- TE is OR-ed in ahead of
    // the latch, so it is safe as a static override. Neither library's
    // synth_exclude.cells lists the icg* cells, so they are available to the
    // flow. Drive strength 1 is the right starting point: CTS buffers the
    // output like any other clock net.
    `ifdef SCL_gf180mcu_fd_sc_mcu7t5v0
        `define CLK_GATE_CELL gf180mcu_fd_sc_mcu7t5v0__icgtp_1
    `endif
    `ifdef SCL_gf180mcu_fd_sc_mcu9t5v0
        `define CLK_GATE_CELL gf180mcu_fd_sc_mcu9t5v0__icgtp_1
    `endif
`endif
`endif

module clk_gate (
    input  wire clk,      // ungated clock
    input  wire en,       // enable, sampled on the low phase of clk
    input  wire test_en,  // static override: forces gclk to follow clk
    output wire gclk      // gated clock
);

`ifdef CLK_GATE_CELL

    // The linter reads the SCL models with USE_POWER_PINS, so the blackbox it
    // sees carries VDD/VSS/VNW/VPW; the flow connects those through the power
    // rails, not through the netlist.
    /* verilator lint_off PINMISSING */
    (* keep *) `CLK_GATE_CELL icg (
        .CLK (clk),
        .E   (en),
        .TE  (test_en),
        .Q   (gclk)
    );
    /* verilator lint_on PINMISSING */

`else

  `ifdef __pnr__
    `ifdef CLK_GATE_FORCE_BEHAVIORAL
    $warning("clk_gate: CLK_GATE_FORCE_BEHAVIORAL in the PnR flow -- the inferred $_DLATCH_N_ has no entry in gf180mcu's latch_map.v and will not map.");
    `else
    $fatal(1, "clk_gate: no integrated clock gate is known for this standard cell library. Add its icgtp equivalent to src/clk_gate.sv, or build a gate from the library's negative-level latch plus an AND -- the behavioural model below is for simulation only and does not map on gf180mcu.");
    `endif
  `endif

    // Mirrors the cell's state table: transparent while CLK is low, holding
    // while CLK is high.
    //
    //   statetable("CLK E TE", "IQ2 IQN2") {
    //     table : "L L L : - - : L H,   L H - : - - : H L,
    //              L - H : - - : H L,   H - - : - - : N N" }
    //
    // No initial value, same as the cell: the first low phase of clk loads it
    // before any rising edge can use it. always_latch rather than always @*
    // keeps the linter's --Werror-LATCH happy.
    reg en_latched;

    always_latch begin
        if (!clk) begin
            en_latched = en | test_en;
        end
    end

    assign gclk = clk & en_latched;

`endif

endmodule

`ifdef CLK_GATE_CELL
`undef CLK_GATE_CELL
`endif

`default_nettype wire
