// SPDX-FileCopyrightText: © 2025 XXX Authors
// SPDX-License-Identifier: Apache-2.0

`default_nettype none

module chip_core #(
    parameter NUM_INPUT_PADS,
    parameter NUM_BIDIR_PADS,
    parameter NUM_ANALOG_PADS
    )(
    `ifdef USE_POWER_PINS
    inout  wire VDD,
    inout  wire VSS,
    `endif
    
    input  wire clk,       // clock
    input  wire rst_n,     // reset (active low)

    input  wire [NUM_INPUT_PADS-1:0] input_in,   // Input value
    output wire [NUM_INPUT_PADS-1:0] input_pu,   // Pull-up
    output wire [NUM_INPUT_PADS-1:0] input_pd,   // Pull-down

    input  wire [NUM_BIDIR_PADS-1:0] bidir_in,   // Input value
    output wire [NUM_BIDIR_PADS-1:0] bidir_out,  // Output value
    output wire [NUM_BIDIR_PADS-1:0] bidir_oe,   // Output enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_cs,   // Input type (0=CMOS Buffer, 1=Schmitt Trigger)
    output wire [NUM_BIDIR_PADS-1:0] bidir_sl,   // Slew rate (0=fast, 1=slow)
    output wire [NUM_BIDIR_PADS-1:0] bidir_ie,   // Input enable
    output wire [NUM_BIDIR_PADS-1:0] bidir_pu,   // Pull-up
    output wire [NUM_BIDIR_PADS-1:0] bidir_pd,   // Pull-down

    inout  wire [NUM_ANALOG_PADS-1:0] analog  // Analog
);

    // ------------------------------------------------------------------
    // Pad assignment
    // ------------------------------------------------------------------
    // The SMAesH driver speaks a bit-serial protocol on Rx/Tx (one bit per
    // clock, no framing -- see smaesh_driver.sv) and raises Trigger for the
    // cycle in which the masked core latches its input, which is what a
    // side-channel setup arms the scope on.
    //
    // All three are placed next to clk/rst_n in the padring. On the target
    // slot_0p5x0p5, inputs[0] is the last PAD_WEST entry -- the south-west
    // corner that PAD_SOUTH starts from with clk_pad -- and bidir[0]/bidir[1]
    // are the first two signal pads along the south edge. Moving the driver
    // to other pads is a matter of changing these three indices and the
    // matching entries in librelane/slots/slot_*.yaml.
    localparam SMAESH_RX_PAD      = 0;  // index into input_*
    localparam SMAESH_TX_PAD      = 0;  // index into bidir_*
    localparam SMAESH_TRIGGER_PAD = 1;  // index into bidir_*

    // The driver owns the two lowest bidir pads; the counter below keeps
    // everything above them.
    localparam SMAESH_BIDIR_PADS = 2;

    localparam [NUM_INPUT_PADS-1:0] SMAESH_RX_MASK = 1 << SMAESH_RX_PAD;

    // See here for usage: https://gf180mcu-pdk.readthedocs.io/en/latest/IPs/IO/gf180mcu_fd_io/digital.html

    // No pulls on the input pads, except a pull-down on Rx: the driver leaves
    // STATE_DEFAULT on the first high bit it sees, so a floating Rx would let
    // noise start a transaction.
    assign input_pu = '0;
    assign input_pd = SMAESH_RX_MASK;

    // Set the bidir as output
    assign bidir_oe = '1;
    assign bidir_cs = '0;
    assign bidir_sl = '0;
    assign bidir_ie = ~bidir_oe;
    assign bidir_pu = '0;
    assign bidir_pd = '0;

    logic _unused;
    assign _unused = &bidir_in;

    // ------------------------------------------------------------------
    // SMAesH driver
    // ------------------------------------------------------------------

    wire smaesh_tx;
    wire smaesh_trigger;

    smaesh_driver driver (
        .clk     (clk),
        .rst_n   (rst_n),

        .Rx      (input_in[SMAESH_RX_PAD]),
        .Tx      (smaesh_tx),
        .Trigger (smaesh_trigger)
    );

    // ------------------------------------------------------------------
    // Template counter, on the bidir pads the driver does not use
    // ------------------------------------------------------------------

    // Force the Rx bit high in the reduction so that driving Rx does not also
    // tick the counter.
    wire count_en = &(input_in | SMAESH_RX_MASK);

    // Only as wide as the pads left over, so every counter bit is observable.
    localparam NUM_COUNT_PADS = NUM_BIDIR_PADS - SMAESH_BIDIR_PADS;

    logic [NUM_COUNT_PADS-1:0] count;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            count <= '0;
        end else begin
            if (count_en) begin
                count <= count + 1;
            end
        end
    end

    assign bidir_out[SMAESH_TX_PAD]                      = smaesh_tx;
    assign bidir_out[SMAESH_TRIGGER_PAD]                 = smaesh_trigger;
    assign bidir_out[NUM_BIDIR_PADS-1:SMAESH_BIDIR_PADS] = count;

endmodule

`default_nettype wire
