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
    // Shifts left both ways: Rx in at bit 0, Tx out from bit 255.
    reg [255:0] Data;
    // Key.
    //
    // Uses least-significant bits for key-sizes less than 256.
    reg [511:0] Key;
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
    localparam [3:0] STATE_RX_MODE_SELECT  = 4'b0001;
    localparam [3:0] STATE_RX_MODE_DECRYPT = 4'b0010;
    localparam [3:0] STATE_RX_DATA_IN      = 4'b0011;
    localparam [3:0] STATE_RX_KEY_IN       = 4'b0100;
    localparam [3:0] STATE_RX_SEED         = 4'b0101;
    localparam [3:0] STATE_EXEC_RESEED     = 4'b1000;
    localparam [3:0] STATE_EXEC_KEY_SET    = 4'b1001;
    localparam [3:0] STATE_EXEC_INIT       = 4'b1010;
    localparam [3:0] STATE_EXEC_RUN        = 4'b1011;
    localparam [3:0] STATE_EXEC_FINISH     = 4'b1100;
    localparam [3:0] STATE_TX_START        = 4'b1110;
    localparam [3:0] STATE_TX_SEND         = 4'b1111;

    // Intra-state counter register.
    reg [8:0] StateCtr;

    wire [31:0] SmaeshKeyData_I;
    wire [1:0] SmaeshKeyCfg_I;
    wire [255:0] SmaeshSharesData_I, SmaeshSharesData_O;
    wire [79:0] SmaeshSeed_I;
    wire SmaeshKeyModeInverse_I,SmaeshKeyValid_I, SmaeshKeyReady_I,
         SmaeshDataValid_I, SmaeshDataReady_I,
         SmaeshSeedValid_I, SmaeshSeedReady_I,
         SmaeshValid_O, SmaeshReady_O;

    smaesh_hpc #( .d(2) ) aes_core (
        .clk                 (clk),
        .rst                 (~rst_n),

        .in_key_data         (SmaeshKeyData_I),
        .in_key_size_cfg     (SmaeshKeyCfg_I),
        .in_key_mode_inverse (SmaeshKeyModeInverse_I),
        .in_key_valid        (SmaeshKeyValid_I),
        .in_key_ready        (SmaeshKeyReady_I),

        .in_data_valid       (SmaeshDataValid_I),
        .in_data_ready       (SmaeshDataReady_I),
        .in_shares_data      (SmaeshSharesData_I),

        .in_seed_valid       (SmaeshSeedValid_I),
        .in_seed_ready       (SmaeshSeedReady_I),
        .in_seed             (SmaeshSeed_I),

        .out_valid           (SmaeshValid_O),
        .out_ready           (SmaeshReady_O),
        .out_shares_data     (SmaeshSharesData_O)
    );

    wire [8:0] NextStateCtr = StateCtr + 1;
    localparam [7:0] LutModeSelectToCfg = 8'b10_01_00_00;

    // Per-state counter limits.
    wire [8:0] DinStateCtrMax =
        (ModeSelect == MODE_SELECT_SBOX) ? (2*8 - 1) : (2*128 - 1);
    wire [8:0] KeyStateCtrMax =
        (ModeSelect == MODE_SELECT_SBOX) ? (2*8 - 1) : (
        (ModeSelect == MODE_SELECT_AES128) ? (2*128 - 1) : (
        (ModeSelect == MODE_SELECT_AES192) ? (2*192 - 1) : (
                                             (2*256 - 1)
        )));
    wire [8:0] ExecKeyStateCtrMax =
        (
             ModeSelect == MODE_SELECT_SBOX
          || ModeSelect == MODE_SELECT_AES128
        ) ? (((2 * 128) / 32) - 1) : (
        (ModeSelect == MODE_SELECT_AES192) ? (((2 * 192) / 32) - 1) : (
                                             (((2 * 256) / 32) - 1)
        ));

    assign SmaeshSeed_I = (State == STATE_EXEC_RESEED) ? Seed : 80'b0;
    assign SmaeshSeedValid_I = State == STATE_EXEC_RESEED;

    assign SmaeshKeyData_I        = (State == STATE_EXEC_KEY_SET) ? Key[32*StateCtr +: 32] : 32'b0;
    assign SmaeshKeyCfg_I         = (State == STATE_EXEC_KEY_SET) ? LutModeSelectToCfg[2*ModeSelect +: 2] : 2'b0;
    assign SmaeshKeyModeInverse_I = (State == STATE_EXEC_KEY_SET) ? ModeDecrypt : 1'b0;
    assign SmaeshKeyValid_I = State == STATE_EXEC_KEY_SET;

    assign SmaeshSharesData_I = (State == STATE_EXEC_INIT) ? Data : 256'b0;
    assign SmaeshDataValid_I = State == STATE_EXEC_INIT;
    assign SmaeshReady_O = State == STATE_EXEC_FINISH;

    assign Tx = (State == STATE_TX_SEND) ? Data[255] : (State == STATE_TX_START);
	assign Trigger = State == STATE_EXEC_INIT;

    always @(posedge clk) begin
        if (~rst_n) begin
            State        <= STATE_DEFAULT;
            StateCtr     <= 9'b0;

            ModeSelect  <= 2'b0;
            ModeDecrypt <= 1'b0;

            Data        <= 256'b0;
            Key         <= 512'b0;
            Seed        <= 80'b0;
        end
        else case (State)
            STATE_DEFAULT: begin 
                StateCtr    <= 9'b0;

                ModeSelect  <= 2'b0;
                ModeDecrypt <= 1'b0;

                Data        <= 256'b0;
                Key         <= 512'b0;
                Seed        <= 80'b0;

                if (Rx) State <= STATE_RX_MODE_SELECT;
            end

            // Receive configuration.
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
                Data <= {Data[254:0], Rx};

                if (StateCtr == DinStateCtrMax) begin
                    State <= STATE_RX_KEY_IN;
                    StateCtr <= 9'b0;
                end
                else StateCtr <= NextStateCtr;
            end
            STATE_RX_KEY_IN: begin
                Key <= {Key[510:0], Rx};

                if (StateCtr == KeyStateCtrMax) begin
                    State <= STATE_RX_SEED;
                    StateCtr <= 9'b0;
                end
                else StateCtr <= NextStateCtr;
            end
            STATE_RX_SEED: begin : SEED_RCV
                localparam [8:0] SeedStateCtrMax = 80 - 1;

                Seed <= {Seed[78:0], Rx};

                if (StateCtr == SeedStateCtrMax) begin
                    State <= STATE_EXEC_RESEED;
                    StateCtr <= 9'b0;
                end
                else StateCtr <= NextStateCtr;
            end

            // Execute the encryption/decryption operation.
            STATE_EXEC_RESEED: begin
                if (SmaeshSeedReady_I) State <= STATE_EXEC_KEY_SET;
            end
            STATE_EXEC_KEY_SET: begin
                if (SmaeshKeyReady_I) begin
                    if (StateCtr == ExecKeyStateCtrMax) begin
                        State    <= STATE_EXEC_INIT;
                        StateCtr <= 0;
                    end
                    else StateCtr <= NextStateCtr;
                end
            end
            STATE_EXEC_INIT: begin
                if (SmaeshDataReady_I) State <= STATE_EXEC_RUN;
            end
            STATE_EXEC_RUN: begin
                if (SmaeshValid_O) State <= STATE_EXEC_FINISH;
            end
            STATE_EXEC_FINISH: begin
                Data  <= SmaeshSharesData_O;
                State <= STATE_TX_START;
            end

            // Transmit the result back.
            STATE_TX_START: State <= STATE_TX_SEND;
            STATE_TX_SEND: begin
                Data <= {Data[254:0], 1'b0};

                if (StateCtr == 9'hFF) begin
                    State <= STATE_DEFAULT;
                    StateCtr <= 9'b0;
                end
                else StateCtr <= NextStateCtr;
            end

            default: State <= STATE_DEFAULT;
        endcase
    end
endmodule

`default_nettype wire
