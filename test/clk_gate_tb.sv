// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0
//
// Testbench for src/clk_gate.sv. Plain Verilog rather than cocotb, because
// what it checks is sub-cycle pulse shape rather than protocol behaviour.
//
//   make sim-clk-gate        behavioural model (no PDK needed)
//   make sim-clk-gate-cell   the real ICG cell; output must match the above
//
// The gated clock is required to carry only full-width pulses, no matter when
// the enable moves. A `gclk = clk & en` reference runs alongside to show what
// that requirement is protecting against: it produces a runt pulse whenever
// the enable falls during the high phase, which is exactly what an enable
// driven by a posedge-clk register does.

`timescale 1ps/1ps
`default_nettype none

module clk_gate_tb;
    // 20 MHz, as in librelane/config.yaml: 50 ns period, 25 ns high.
    localparam integer HALF_PS = 25000;

    reg clk = 1'b0;
    reg en  = 1'b0;
    wire gclk;

    // The naive version, for contrast only.
    wire gclk_and = clk & en;

    clk_gate dut (
        .clk     (clk),
        .en      (en),
        .test_en (1'b0),
        .gclk    (gclk)
    );

    always #HALF_PS clk = ~clk;

    integer edges_clk = 0, edges_gclk = 0, edges_and = 0;
    integer runts = 0, runts_and = 0;
    time last_rise = 0, last_rise_and = 0;

    always @(posedge clk) edges_clk = edges_clk + 1;

    always @(posedge gclk) begin
        edges_gclk = edges_gclk + 1;
        last_rise = $time;
        $display("%0t GCLK rise", $time);
    end
    always @(negedge gclk) begin
        if ($time - last_rise != HALF_PS) begin
            runts = runts + 1;
            $display("%0t GCLK RUNT pulse: %0t ps wide", $time, $time - last_rise);
        end
    end

    always @(posedge gclk_and) begin
        edges_and = edges_and + 1;
        last_rise_and = $time;
    end
    always @(negedge gclk_and) begin
        if ($time - last_rise_and != HALF_PS) begin
            runts_and = runts_and + 1;
            $display("%0t AND  RUNT pulse: %0t ps wide", $time, $time - last_rise_and);
        end
    end

    initial begin
        // Three cycles with the gate closed.
        repeat (3) @(posedge clk);

        // Open it, moving the enable 500 ps after a rising edge -- what an
        // ImplSelect flop actually does.
        @(posedge clk); #500 en = 1'b1;
        repeat (4) @(posedge clk);

        // Close it the same way. This is the case that breaks a bare AND.
        @(posedge clk); #500 en = 1'b0;
        repeat (3) @(posedge clk);

        // Open it mid low-phase; the latch has to pass that through in the
        // same cycle, like the cell does.
        @(negedge clk); #5000 en = 1'b1;
        repeat (3) @(posedge clk);

        // And move it exactly on a rising edge, the nastiest alignment.
        @(posedge clk) en = 1'b0;
        repeat (3) @(posedge clk);

        $display("RESULT clk=%0d gclk=%0d and=%0d runts_gclk=%0d runts_and=%0d",
                 edges_clk, edges_gclk, edges_and, runts, runts_and);

        if (runts != 0) begin
            $fatal(1, "FAIL: the gated clock had %0d malformed pulse(s)", runts);
        end
        if (edges_gclk != 9) begin
            $fatal(1, "FAIL: expected 9 gated clock edges, got %0d", edges_gclk);
        end
        if (runts_and == 0) begin
            $fatal(1, "FAIL: the AND reference produced no runt pulse, so this testbench is no longer exercising the hazard");
        end

        $display("PASS: %0d full-width gclk pulses, no runts (the AND reference had %0d)",
                 edges_gclk, runts_and);
        $finish;
    end
endmodule

`default_nettype wire
