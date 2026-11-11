// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0

// Clock gating, as a macro rather than a module.
//
//     `CLK_GATE(icg_m2, clk, en_m2, 1'b0, clk_m2)
//
// expands in place: no wrapper module, so nothing is added to the hierarchy.
// That matters here because the design is synthesised with
// SYNTH_HIERARCHY_MODE: keep and slang's --keep-hierarchy to protect the
// masking gadgets, which would otherwise preserve one wrapper level per gate.
// Note there is no trailing semicolon at the call site -- the expansion ends
// with either an instantiation or a generate block.
//
// `gclk_o` follows `clk_i` while `en_i` (or `test_en_i`) is high, and is held
// low otherwise. `en_i` is sampled during the *low* phase of `clk_i` and held
// through the high phase, so `gclk_o` carries either a full-width `clk_i` pulse
// or no pulse at all. That is the entire point: the enables this is for come
// from posedge-`clk` registers (ImplSelect), so they change while `clk` is
// still high, and a plain `gclk = clk & en` would chop the pulse in flight down
// to the enable path delay -- well under the 0.96 ns min_pulse_width_high that
// gf180mcu_fd_sc_mcu7t5v0__dffq_1 needs at ss_125C_4v50. The gated flops would
// then capture inconsistently, which for a masked core means some shares update
// and others do not: the clock-glitch fault model, built in by accident.
//
// A bare AND would also *simulate* fine. Verilog's delta-cycle ordering turns
// the runt pulse into a zero-width glitch that no `always @(posedge)` reacts
// to, so the failure only ever appears in silicon -- which is why this is not
// something an RTL test would have caught for you.
//
// Which expansion is used:
//
//   - LibreLane (which defines `__pnr__`) with an SCL that has an integrated
//     clock gate: the ICG cell, instantiated directly at the call site. STA
//     then checks the enable against CLK through the cell's
//     setup_rising/hold_rising arcs, and CTS recognises it as a clock gate
//     rather than as stray combinational logic in the clock path.
//   - Any simulator -- with or without the SCL_* defines that both the flow
//     and cocotb set -- gets the behavioural latch, which mirrors the cell's
//     state table exactly, and was checked against the cell's own verilog
//     model under Icarus (identical gated-clock waveform).
//
// The behavioural latch is deliberately not a synthesis fallback: it infers a
// negative-level-sensitive latch, and gf180mcu's latch_map.v maps only
// $_DLATCH_P_/$_DLATCH_PN0_/$_DLATCH_PN1_, so $_DLATCH_N_ survives dfflibmap
// and abc unmapped. Expanding this in the flow without a usable ICG therefore
// fails at elaboration with the message below. gf180mcu_as_sc_mcu7t3v3 is that
// case: no icg* cells at all, and no latch_map.v either, so it needs a gate
// hand-built from its dlxtn_2 + and2_2.
//
// Gate-level simulation never sees any of this: the netlist is flat and carries
// the cell.
//
// Define CLK_GATE_FORCE_BEHAVIORAL to take the behavioural path in simulation
// even when an SCL with an ICG is selected.

`ifndef CLK_GATE_SVH
`define CLK_GATE_SVH

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

`ifdef CLK_GATE_CELL

// The linter reads the SCL models with USE_POWER_PINS, so the blackbox it sees
// carries VDD/VSS/VNW/VPW. The flow connects those through the power rails
// rather than the netlist, so they are left unconnected here, and the pragma
// below suppresses the PINMISSING that would otherwise be reported once per
// gate. Verilator does keep a block comment inside a macro body -- checked,
// not assumed.
`define CLK_GATE(inst, clk_i, en_i, test_en_i, gclk_o) \
    /* verilator lint_off PINMISSING */ \
    (* keep *) `CLK_GATE_CELL inst ( \
        .CLK (clk_i), \
        .E   (en_i), \
        .TE  (test_en_i), \
        .Q   (gclk_o) \
    ); \
    /* verilator lint_on PINMISSING */

`elsif __pnr__

`define CLK_GATE(inst, clk_i, en_i, test_en_i, gclk_o) \
    if (1) begin : inst \
        $fatal(1, "clk_gate: no usable integrated clock gate for this standard cell library (or CLK_GATE_FORCE_BEHAVIORAL is set). Add the library's icgtp equivalent to src/clk_gate.svh, or build a gate from its negative-level latch plus an AND: the behavioural latch is for simulation only, because gf180mcu's latch_map.v has no $_DLATCH_N_ entry and it would not map."); \
    end

`else

// Mirrors the cell's state table: transparent while CLK is low, holding while
// CLK is high.
//
//   statetable("CLK E TE", "IQ2 IQN2") {
//     table : "L L L : - - : L H,   L H - : - - : H L,
//              L - H : - - : H L,   H - - : - - : N N" }
//
// The generate block is only there to scope `en_latched` to the call site, so
// the name matches the cell instance the flow would have put there; it adds no
// hierarchy. No initial value, same as the cell: the first low phase of clk
// loads it before any rising edge can use it. always_latch rather than
// always @* keeps the linter's --Werror-LATCH happy.
`define CLK_GATE(inst, clk_i, en_i, test_en_i, gclk_o) \
    if (1) begin : inst \
        reg en_latched; \
        always_latch begin \
            if (!(clk_i)) begin \
                en_latched = (en_i) | (test_en_i); \
            end \
        end \
        assign gclk_o = (clk_i) & en_latched; \
    end

`endif

`endif
