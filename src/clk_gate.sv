// SPDX-FileCopyrightText: © 2026 XXX Authors
// SPDX-License-Identifier: Apache-2.0

// Clock gating
//     `CLK_GATE(icg_m2, clk, en_m2, 1'b0, clk_m2)

`ifndef CLK_GATE_SVH
`define CLK_GATE_SVH

`ifndef CLK_GATE_FORCE_BEHAVIORAL
`ifdef __pnr__
    `ifdef SCL_gf180mcu_fd_sc_mcu7t5v0
        `define CLK_GATE_CELL gf180mcu_fd_sc_mcu7t5v0__icgtp_1
    `endif
    `ifdef SCL_gf180mcu_fd_sc_mcu9t5v0
        `define CLK_GATE_CELL gf180mcu_fd_sc_mcu9t5v0__icgtp_1
    `endif
`endif
`endif

`ifdef CLK_GATE_CELL

`define CLK_GATE(inst, clk_i, en_i, test_en_i, gclk_o) \
    (* keep *) `CLK_GATE_CELL inst ( \
        .CLK (clk_i), \
        .E   (en_i), \
        .TE  (test_en_i), \
        .Q   (gclk_o) \
    );

`elsif __pnr__

`define CLK_GATE(inst, clk_i, en_i, test_en_i, gclk_o) \
    if (1) begin : inst \
        $fatal(1, "clk_gate: no usable integrated clock gate for this standard cell library"); \
    end

`else

// Mirrors the cell's state table: transparent while CLK is low, holding while
// CLK is high.
//
//   statetable("CLK E TE", "IQ2 IQN2") {
//     table : "L L L : - - : L H,   L H - : - - : H L,
//              L - H : - - : H L,   H - - : - - : N N" }
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
