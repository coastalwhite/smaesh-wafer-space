`include "clk_gate.sv"

`default_nettype none

// A very simple driver for the SMAesH HPC core.
//
// A state machine receives input data, executes and transmits output data.
module smaesh_driver(
    input wire clk,
    input wire rst_n,

    input wire Rx,
    output wire Tx,
	output wire Trigger
);
    // Input sharing, then the result sharing. Their lifetimes do not overlap.
    // Shifts left both ways: Rx in at bit 0, Tx out from bit 255 (d=2) or
    // bit 383 (d=3), depending on ImplSelect.
    reg [383:0] Data;
    // Key.
    //
    // Uses least-significant bits for key-sizes less than 256.
    reg [767:0] Key;
    // Pseudo-Random Number Seed.
    reg [79:0] Seed;

    // Select between encryption (1'b0) and decryption (1'b1).
    reg ModeDecrypt;

    // Select encryption mode.
    reg        [1:0] ModeSelect;
    localparam [1:0] MODE_SELECT_SBOX   = 2'b00;
    localparam [1:0] MODE_SELECT_AES128 = 2'b01;
    localparam [1:0] MODE_SELECT_AES192 = 2'b10;
    localparam [1:0] MODE_SELECT_AES256 = 2'b11;

    // State register for handling encryption.
    reg        [3:0] State;
    localparam [3:0] STATE_DEFAULT         = 4'b0000;
    localparam [3:0] STATE_RX_IMPL_SELECT  = 4'b0001;
    localparam [3:0] STATE_RX_MODE_SELECT  = 4'b0010;
    localparam [3:0] STATE_RX_MODE_DECRYPT = 4'b0011;
    localparam [3:0] STATE_RX_DATA_IN      = 4'b0100;
    localparam [3:0] STATE_RX_KEY_IN       = 4'b0101;
    localparam [3:0] STATE_RX_SEED         = 4'b0110;
    localparam [3:0] STATE_EXEC_RESEED     = 4'b1000;
    localparam [3:0] STATE_EXEC_KEY_SET    = 4'b1001;
    localparam [3:0] STATE_EXEC_INIT       = 4'b1010;
    localparam [3:0] STATE_EXEC_FULL       = 4'b1011;
    localparam [3:0] STATE_EXEC_SBOX       = 4'b1100;
    localparam [3:0] STATE_EXEC_FINISH     = 4'b1101;
    localparam [3:0] STATE_TX_START        = 4'b1110;
    localparam [3:0] STATE_TX_SEND         = 4'b1111;

    // Intra-state counter register.
    reg [9:0] StateCtr;

    // Selection between M2 and M3 implementations.
    reg ImplSelect;
    localparam IMPL_M2 = 1'b0;
    localparam IMPL_M3 = 1'b1;

    wire Smaesh2GatedClk, Smaesh3GatedClk, Sbox2GatedClk, Sbox3GatedClk;
    // Don't clock gate when resetting or when we don't know the core yet. Cores
    // should still have a few cycles to settle and cool down when transferring
    // data.
    wire CoresOpen = ~rst_n | (State == STATE_DEFAULT | State == STATE_RX_IMPL_SELECT | State == STATE_RX_MODE_SELECT);
    `CLK_GATE(clkgate_aes2,  clk, (CoresOpen | ((ImplSelect == IMPL_M2) & (ModeSelect != MODE_SELECT_SBOX))), 1'b0, Smaesh2GatedClk)
    `CLK_GATE(clkgate_aes3,  clk, (CoresOpen | ((ImplSelect == IMPL_M3) & (ModeSelect != MODE_SELECT_SBOX))), 1'b0, Smaesh3GatedClk)
    `CLK_GATE(clkgate_sbox2, clk, (CoresOpen | ((ImplSelect == IMPL_M2) & (ModeSelect == MODE_SELECT_SBOX))), 1'b0, Sbox2GatedClk)
    `CLK_GATE(clkgate_sbox3, clk, (CoresOpen | ((ImplSelect == IMPL_M3) & (ModeSelect == MODE_SELECT_SBOX))), 1'b0, Sbox3GatedClk)

    wire [31:0] Smaesh2KeyData_I;
    wire [1:0] Smaesh2KeyCfg_I;
    wire [255:0] Smaesh2SharesData_I, Smaesh2SharesData_O;
    wire [79:0] Smaesh2Seed_I;
    wire Smaesh2KeyModeInverse_I,Smaesh2KeyValid_I, Smaesh2KeyReady_I,
         Smaesh2DataValid_I, Smaesh2DataReady_I,
         Smaesh2SeedValid_I, Smaesh2SeedReady_I,
         Smaesh2Valid_O, Smaesh2Ready_O;

    wire [31:0] Smaesh3KeyData_I;
    wire [1:0] Smaesh3KeyCfg_I;
    wire [383:0] Smaesh3SharesData_I, Smaesh3SharesData_O;
    wire [79:0] Smaesh3Seed_I;
    wire Smaesh3KeyModeInverse_I,Smaesh3KeyValid_I, Smaesh3KeyReady_I,
         Smaesh3DataValid_I, Smaesh3DataReady_I,
         Smaesh3SeedValid_I, Smaesh3SeedReady_I,
         Smaesh3Valid_O, Smaesh3Ready_O;

    smaesh_hpc #( .d(2) ) aes_core_m2 (
        .clk                 (Smaesh2GatedClk),
        .rst                 (~rst_n),

        .in_key_data         (Smaesh2KeyData_I),
        .in_key_size_cfg     (Smaesh2KeyCfg_I),
        .in_key_mode_inverse (Smaesh2KeyModeInverse_I),
        .in_key_valid        (Smaesh2KeyValid_I),
        .in_key_ready        (Smaesh2KeyReady_I),

        .in_data_valid       (Smaesh2DataValid_I),
        .in_data_ready       (Smaesh2DataReady_I),
        .in_shares_data      (Smaesh2SharesData_I),

        .in_seed_valid       (Smaesh2SeedValid_I),
        .in_seed_ready       (Smaesh2SeedReady_I),
        .in_seed             (Smaesh2Seed_I),

        .out_valid           (Smaesh2Valid_O),
        .out_ready           (Smaesh2Ready_O),
        .out_shares_data     (Smaesh2SharesData_O)
    );
    smaesh_hpc #( .d(3) ) aes_core_m3 (
        .clk                 (Smaesh3GatedClk),
        .rst                 (~rst_n),

        .in_key_data         (Smaesh3KeyData_I),
        .in_key_size_cfg     (Smaesh3KeyCfg_I),
        .in_key_mode_inverse (Smaesh3KeyModeInverse_I),
        .in_key_valid        (Smaesh3KeyValid_I),
        .in_key_ready        (Smaesh3KeyReady_I),

        .in_data_valid       (Smaesh3DataValid_I),
        .in_data_ready       (Smaesh3DataReady_I),
        .in_shares_data      (Smaesh3SharesData_I),

        .in_seed_valid       (Smaesh3SeedValid_I),
        .in_seed_ready       (Smaesh3SeedReady_I),
        .in_seed             (Smaesh3Seed_I),

        .out_valid           (Smaesh3Valid_O),
        .out_ready           (Smaesh3Ready_O),
        .out_shares_data     (Smaesh3SharesData_O)
    );

    localparam [9:0] SBOX_LATENCY = 4;

    // Randomness demanded by one S-Box per cycle.
    localparam integer SBOX_M2_RND_BUS0 = 4*2*(2-1);  //  8
    localparam integer SBOX_M2_RND_BUS1 = 2*2*(2-1);  //  4
    localparam integer SBOX_M2_RND_BUS2 = 4*2*(2-1);  //  8
    localparam integer SBOX_M2_RND_BUS3 = 8*2*(2-1);  // 16
    localparam integer SBOX_M3_RND_BUS0 = 4*3*(3-1);  // 24
    localparam integer SBOX_M3_RND_BUS1 = 2*3*(3-1);  // 12
    localparam integer SBOX_M3_RND_BUS2 = 4*3*(3-1);  // 24
    localparam integer SBOX_M3_RND_BUS3 = 8*3*(3-1);  // 48

    localparam integer SBOX_M2_RND_TOTAL = SBOX_M2_RND_BUS0 + SBOX_M2_RND_BUS1
                                         + SBOX_M2_RND_BUS2 + SBOX_M2_RND_BUS3;
    localparam integer SBOX_M3_RND_TOTAL = SBOX_M3_RND_BUS0 + SBOX_M3_RND_BUS1
                                         + SBOX_M3_RND_BUS2 + SBOX_M3_RND_BUS3;

    wire SboxMode = ModeSelect == MODE_SELECT_SBOX;

    wire [8*2-1:0] Sbox2Shares_I = ((State == STATE_EXEC_SBOX) & (ImplSelect == IMPL_M2))
        ? Data[8*2-1:0] : {(8*2){1'b0}};
    wire [8*2-1:0] Sbox2Shbus_I;
    wire [8*2-1:0] Sbox2Shbus_O;
    wire [8*2-1:0] Sbox2Shares_O;

    wire [8*3-1:0] Sbox3Shares_I = ((State == STATE_EXEC_SBOX) & (ImplSelect == IMPL_M3))
        ? Data[8*3-1:0] : {(8*3){1'b0}};
    wire [8*3-1:0] Sbox3Shbus_I;
    wire [8*3-1:0] Sbox3Shbus_O;
    wire [8*3-1:0] Sbox3Shares_O;

    shares2shbus #(.d(2), .count(8)) sbox_m2_in_encoding (
        .shares (Sbox2Shares_I),
        .shbus  (Sbox2Shbus_I)
    );
    shbus2shares #(.d(2), .count(8)) sbox_m2_out_encoding (
        .shbus  (Sbox2Shbus_O),
        .shares (Sbox2Shares_O)
    );

    shares2shbus #(.d(3), .count(8)) sbox_m3_in_encoding (
        .shares (Sbox3Shares_I),
        .shbus  (Sbox3Shbus_I)
    );
    shbus2shares #(.d(3), .count(8)) sbox_m3_out_encoding (
        .shbus  (Sbox3Shbus_O),
        .shares (Sbox3Shares_O)
    );

    gen_sbox #( .d(2) ) sbox_m2 (
        .clk       (Sbox2GatedClk),
        .i0        (Sbox2Shbus_I[0*2 +: 2]),
        .i1        (Sbox2Shbus_I[1*2 +: 2]),
        .i2        (Sbox2Shbus_I[2*2 +: 2]),
        .i3        (Sbox2Shbus_I[3*2 +: 2]),
        .i4        (Sbox2Shbus_I[4*2 +: 2]),
        .i5        (Sbox2Shbus_I[5*2 +: 2]),
        .i6        (Sbox2Shbus_I[6*2 +: 2]),
        .i7        (Sbox2Shbus_I[7*2 +: 2]),
        .rnd_bus0w (Key[0 +: SBOX_M2_RND_BUS0]),
        .rnd_bus1w (Key[SBOX_M2_RND_BUS0 +: SBOX_M2_RND_BUS1]),
        .rnd_bus2w (Key[SBOX_M2_RND_BUS0 + SBOX_M2_RND_BUS1 +: SBOX_M2_RND_BUS2]),
        .rnd_bus3w (Key[SBOX_M2_RND_BUS0 + SBOX_M2_RND_BUS1 + SBOX_M2_RND_BUS2 +: SBOX_M2_RND_BUS3]),
        .inverse   (ModeDecrypt),
        .o0        (Sbox2Shbus_O[0*2 +: 2]),
        .o1        (Sbox2Shbus_O[1*2 +: 2]),
        .o2        (Sbox2Shbus_O[2*2 +: 2]),
        .o3        (Sbox2Shbus_O[3*2 +: 2]),
        .o4        (Sbox2Shbus_O[4*2 +: 2]),
        .o5        (Sbox2Shbus_O[5*2 +: 2]),
        .o6        (Sbox2Shbus_O[6*2 +: 2]),
        .o7        (Sbox2Shbus_O[7*2 +: 2])
    );


    gen_sbox #( .d(3) ) sbox_m3 (
        .clk       (Sbox3GatedClk),
        .i0        (Sbox3Shbus_I[0*3 +: 3]),
        .i1        (Sbox3Shbus_I[1*3 +: 3]),
        .i2        (Sbox3Shbus_I[2*3 +: 3]),
        .i3        (Sbox3Shbus_I[3*3 +: 3]),
        .i4        (Sbox3Shbus_I[4*3 +: 3]),
        .i5        (Sbox3Shbus_I[5*3 +: 3]),
        .i6        (Sbox3Shbus_I[6*3 +: 3]),
        .i7        (Sbox3Shbus_I[7*3 +: 3]),
        .rnd_bus0w (Key[0 +: SBOX_M3_RND_BUS0]),
        .rnd_bus1w (Key[SBOX_M3_RND_BUS0 +: SBOX_M3_RND_BUS1]),
        .rnd_bus2w (Key[SBOX_M3_RND_BUS0 + SBOX_M3_RND_BUS1 +: SBOX_M3_RND_BUS2]),
        .rnd_bus3w (Key[SBOX_M3_RND_BUS0 + SBOX_M3_RND_BUS1 + SBOX_M3_RND_BUS2 +: SBOX_M3_RND_BUS3]),
        .inverse   (ModeDecrypt),
        .o0        (Sbox3Shbus_O[0*3 +: 3]),
        .o1        (Sbox3Shbus_O[1*3 +: 3]),
        .o2        (Sbox3Shbus_O[2*3 +: 3]),
        .o3        (Sbox3Shbus_O[3*3 +: 3]),
        .o4        (Sbox3Shbus_O[4*3 +: 3]),
        .o5        (Sbox3Shbus_O[5*3 +: 3]),
        .o6        (Sbox3Shbus_O[6*3 +: 3]),
        .o7        (Sbox3Shbus_O[7*3 +: 3])
    );

    wire [9:0] NextStateCtr = StateCtr + 1;
    localparam [7:0] LutModeSelectToCfg = 8'b10_01_00_00;

    // Per-state counter limits.
    wire [9:0] DinStateCtrMax = (ImplSelect == IMPL_M2)
        ? ((ModeSelect == MODE_SELECT_SBOX) ? (2*8 - 1) : (2*128 - 1))
        : ((ModeSelect == MODE_SELECT_SBOX) ? (3*8 - 1) : (3*128 - 1));

    // In S-Box mode the Key register contains the randomness.
    wire [9:0] KeyStateCtrMax = (ImplSelect == IMPL_M2)
        ? (
            (ModeSelect == MODE_SELECT_SBOX) ? (10'(SBOX_M2_RND_TOTAL - 1)) : (
            (ModeSelect == MODE_SELECT_AES128) ? (2*128 - 1) : (
            (ModeSelect == MODE_SELECT_AES192) ? (2*192 - 1) : (
                                                 (2*256 - 1)
            )))
        )
        : (
            (ModeSelect == MODE_SELECT_SBOX) ? (10'(SBOX_M3_RND_TOTAL - 1)) : (
            (ModeSelect == MODE_SELECT_AES128) ? (3*128 - 1) : (
            (ModeSelect == MODE_SELECT_AES192) ? (3*192 - 1) : (
                                                 (3*256 - 1)
            )))
        );
    wire [9:0] ExecKeyStateCtrMax = (ImplSelect == IMPL_M2)
        ? (
            (
                 ModeSelect == MODE_SELECT_SBOX
              || ModeSelect == MODE_SELECT_AES128
            ) ? (((2 * 128) / 32) - 1) : (
            (ModeSelect == MODE_SELECT_AES192) ? (((2 * 192) / 32) - 1) : (
                                                 (((2 * 256) / 32) - 1)
            ))
        )
        : (
            (
                 ModeSelect == MODE_SELECT_SBOX
              || ModeSelect == MODE_SELECT_AES128
            ) ? (((3 * 128) / 32) - 1) : (
            (ModeSelect == MODE_SELECT_AES192) ? (((3 * 192) / 32) - 1) : (
                                                 (((3 * 256) / 32) - 1)
            ))
        );
    wire [9:0] TxSendStateCtrMax = SboxMode
        ? ((ImplSelect == IMPL_M2) ? (2*8 - 1) : (3*8 - 1))
        : ((ImplSelect == IMPL_M2) ? 10'd255   : 10'd383);

	wire SmaeshSeedReady_I = (ImplSelect == IMPL_M2) ? Smaesh2SeedReady_I : Smaesh3SeedReady_I;
	wire SmaeshKeyReady_I = (ImplSelect == IMPL_M2) ? Smaesh2KeyReady_I : Smaesh3KeyReady_I;
	wire SmaeshDataReady_I = (ImplSelect == IMPL_M2) ? Smaesh2DataReady_I : Smaesh3DataReady_I;
	wire SmaeshValid_O = (ImplSelect == IMPL_M2) ? Smaesh2Valid_O : Smaesh3Valid_O;

    assign Smaesh2Seed_I = (State == STATE_EXEC_RESEED & ImplSelect == IMPL_M2) ? Seed : 80'b0;
    assign Smaesh2SeedValid_I = State == STATE_EXEC_RESEED & ImplSelect == IMPL_M2;

    assign Smaesh2KeyData_I        = (State == STATE_EXEC_KEY_SET & ImplSelect == IMPL_M2) ? Key[31:0] : 32'b0;
    assign Smaesh2KeyCfg_I         = (State == STATE_EXEC_KEY_SET & ImplSelect == IMPL_M2) ? LutModeSelectToCfg[2*ModeSelect +: 2] : 2'b0;
    assign Smaesh2KeyModeInverse_I = (State == STATE_EXEC_KEY_SET & ImplSelect == IMPL_M2) ? ModeDecrypt : 1'b0;
    assign Smaesh2KeyValid_I = State == STATE_EXEC_KEY_SET & ImplSelect == IMPL_M2;

    assign Smaesh2SharesData_I = (State == STATE_EXEC_INIT & ImplSelect == IMPL_M2) ? Data[255:0] : 256'b0;
    assign Smaesh2DataValid_I = State == STATE_EXEC_INIT & ImplSelect == IMPL_M2;
    assign Smaesh2Ready_O = State == STATE_EXEC_FINISH & ImplSelect == IMPL_M2;

    assign Smaesh3Seed_I = (State == STATE_EXEC_RESEED & ImplSelect == IMPL_M3) ? Seed : 80'b0;
    assign Smaesh3SeedValid_I = State == STATE_EXEC_RESEED & ImplSelect == IMPL_M3;

    assign Smaesh3KeyData_I        = (State == STATE_EXEC_KEY_SET & ImplSelect == IMPL_M3) ? Key[31:0] : 32'b0;
    assign Smaesh3KeyCfg_I         = (State == STATE_EXEC_KEY_SET & ImplSelect == IMPL_M3) ? LutModeSelectToCfg[2*ModeSelect +: 2] : 2'b0;
    assign Smaesh3KeyModeInverse_I = (State == STATE_EXEC_KEY_SET & ImplSelect == IMPL_M3) ? ModeDecrypt : 1'b0;
    assign Smaesh3KeyValid_I = State == STATE_EXEC_KEY_SET & ImplSelect == IMPL_M3;

    assign Smaesh3SharesData_I = (State == STATE_EXEC_INIT & ImplSelect == IMPL_M3) ? Data[383:0] : 384'b0;
    assign Smaesh3DataValid_I = State == STATE_EXEC_INIT & ImplSelect == IMPL_M3;
    assign Smaesh3Ready_O = State == STATE_EXEC_FINISH & ImplSelect == IMPL_M3;

    assign Tx = (State == STATE_TX_SEND)
	    ? (SboxMode
	        ? ((ImplSelect == IMPL_M2) ? Data[2*8 - 1] : Data[3*8 - 1])
	        : ((ImplSelect == IMPL_M2) ? Data[255]     : Data[383]))
		: (State == STATE_TX_START);

	// Marks the computation in either mode:
	// - Full AES: STATE_EXEC_INIT -> STATE_EXEC_FULL -> STATE_EXEC_FINISH
	// - S-Box:    STATE_EXEC_INIT -> STATE_EXEC_SBOX -> STATE_EXEC_FINISH
	assign Trigger =
	      (State == STATE_EXEC_INIT)
	    | (State == STATE_EXEC_FULL)
		| (State == STATE_EXEC_FINISH)
		| (State == STATE_EXEC_SBOX);

    always @(posedge clk) begin
        if (~rst_n) begin
            State        <= STATE_DEFAULT;
            StateCtr     <= 10'b0;
            ImplSelect   <= IMPL_M2;

            ModeSelect  <= 2'b0;
            ModeDecrypt <= 1'b0;

            Data        <= 384'b0;
            Key         <= 768'b0;
            Seed        <= 80'b0;
        end
        else case (State)
            STATE_DEFAULT: begin 
                StateCtr    <= 10'b0;
                ImplSelect  <= IMPL_M2;

                ModeSelect  <= 2'b0;
                ModeDecrypt <= 1'b0;

                Data        <= 384'b0;
                Key         <= 768'b0;
                Seed        <= 80'b0;

                if (Rx) State <= STATE_RX_IMPL_SELECT;
            end

            // Receive configuration.
            STATE_RX_IMPL_SELECT: begin 
                ImplSelect <= Rx;
				State <= STATE_RX_MODE_SELECT;
            end
            STATE_RX_MODE_SELECT: begin 
                ModeSelect <= {ModeSelect[0], Rx};
                
                if (StateCtr[0]) State <= STATE_RX_MODE_DECRYPT;
                StateCtr[0] <= ~StateCtr[0];
            end
            STATE_RX_MODE_DECRYPT: begin 
                ModeDecrypt <= Rx;

                State <= STATE_RX_DATA_IN;
            end

            // Receive main data chunks.
            STATE_RX_DATA_IN: begin
                Data <= {Data[382:0], Rx};

                if (StateCtr == DinStateCtrMax) begin
                    State <= STATE_RX_KEY_IN;
                    StateCtr <= 10'b0;
                end
                else StateCtr <= NextStateCtr;
            end
            STATE_RX_KEY_IN: begin
                Key <= {Key[766:0], Rx};

                if (StateCtr == KeyStateCtrMax) begin
                    State <= SboxMode ? STATE_EXEC_INIT : STATE_RX_SEED;
                    StateCtr <= 10'b0;
                end
                else StateCtr <= NextStateCtr;
            end
            STATE_RX_SEED: begin : SEED_RCV
                localparam [9:0] SeedStateCtrMax = 80 - 1;

                Seed <= {Seed[78:0], Rx};

                if (StateCtr == SeedStateCtrMax) begin
                    State <= STATE_EXEC_RESEED;
                    StateCtr <= 10'b0;
                end
                else StateCtr <= NextStateCtr;
            end

            // Execute the encryption/decryption operation.
            STATE_EXEC_RESEED: begin
                if (SmaeshSeedReady_I)
                    State <= STATE_EXEC_KEY_SET;
            end
            STATE_EXEC_KEY_SET: begin
                if (SmaeshKeyReady_I) begin
                    Key <= {32'b0, Key[767:32]};
                    if (StateCtr == ExecKeyStateCtrMax) begin
                        State    <= STATE_EXEC_INIT;
                        StateCtr <= 0;
                    end
                    else StateCtr <= NextStateCtr;
                end
            end
            STATE_EXEC_INIT: begin
                if (SboxMode)
                    State <= STATE_EXEC_SBOX;
                else if (SmaeshDataReady_I)
                    State <= STATE_EXEC_FULL;
            end
            STATE_EXEC_FULL: begin
                if (SmaeshValid_O)
                    State <= STATE_EXEC_FINISH;
            end
            STATE_EXEC_SBOX: begin
                if (StateCtr == SBOX_LATENCY) begin
                    State    <= STATE_EXEC_FINISH;
                    StateCtr <= 10'b0;
                end
                else StateCtr <= NextStateCtr;
            end
            STATE_EXEC_FINISH: begin
                Data  <= SboxMode
				    ? (
						(ImplSelect == IMPL_M2)
						    ? { {(384 - 2*8){1'b0}}, Sbox2Shares_O }
 							: { {(384 - 3*8){1'b0}}, Sbox3Shares_O }
					)
					: (
						(ImplSelect == IMPL_M2)
						? { 128'b0, Smaesh2SharesData_O }
						: Smaesh3SharesData_O
					);
                State <= STATE_TX_START;
            end

            // Transmit the result back.
            STATE_TX_START: State <= STATE_TX_SEND;
            STATE_TX_SEND: begin
                Data <= {Data[382:0], 1'b0};

                if (StateCtr == TxSendStateCtrMax) begin
                    State <= STATE_DEFAULT;
                    StateCtr <= 10'b0;
                end
                else StateCtr <= NextStateCtr;
            end

            default: State <= STATE_DEFAULT;
        endcase
    end
endmodule

`default_nettype wire
