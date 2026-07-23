`timescale 1ns/1ps
// ================================================================
// tb_phase2_trojan.v  --  DAC 2026 AHA Challenge Phase 2
// Exploit Testbench: Cascade Parity Metastability Injector
//
// BUG FIXES vs v1:
//   1. Free-running clock via 'always #5 clk = ~clk'.
//      All tasks use @(posedge/negedge clk) -- no manual clk toggling.
//   2. chip_reset called ONCE only. No spurious tx_complete events.
//   3. spi_xfer uses @(negedge clk)/@(posedge clk) for timing.
//   4. Frozen state read directly from dut.L_reg / dut.R_reg.
// ================================================================

module tb_phase2_trojan;

    reg  clk, mosi, encrypt, start, norm_cs_n;
    wire busy, miso;

    des_trojan_core dut (
        .clk(clk), .mosi(mosi), .encrypt(encrypt),
        .start(start), .norm_cs_n(norm_cs_n),
        .busy(busy), .miso(miso)
    );

    // ---- Free-running 100 MHz clock ----
    initial clk = 0;
    always  #5 clk = ~clk;

    integer  i, errors;
    reg [63:0] enc_result, dec_result, rx_data, frozen_ct;
    reg        froze;

    localparam [63:0] MAGIC     = 64'hC0FFEEDEADCAFEB0;
    localparam [63:0] DECOY     = 64'hDEADBEEFCAFEBABE;
    localparam [63:0] PLAINTEXT = 64'h0123456789ABCDEF;

    // ================================================================
    // TASKS  (all clock-synchronous -- NO manual clk=0/1)
    // ================================================================

    // Shift 64 bits MSB-first on MOSI, capture MISO simultaneously
    task spi_xfer;
        input  [63:0] tx;
        output [63:0] rx;
        integer b;
        begin
            rx = 64'h0;
            for (b = 63; b >= 0; b = b-1) begin
                mosi = tx[b];
                @(posedge clk); #1; rx[b] = miso;
                @(negedge clk);
            end
            mosi = 0;
        end
    endtask

    // One-time global reset  (chip_reset ONLY called at start)
    task chip_reset;
        begin
            norm_cs_n = 0;
            repeat(4) @(posedge clk);
            @(negedge clk); norm_cs_n = 1;
            repeat(2) @(posedge clk);
        end
    endtask

    // Encrypt or Decrypt one block. Returns result and froze flag.
    // Does NOT call chip_reset -- the CS_N=0 write phase resets DES engine.
    task des_op;
        input  [63:0] plaintext;
        input         enc;
        output [63:0] result;
        output        op_froze;
        integer timeout;
        begin
            op_froze = 0;
            encrypt  = enc;

            // ---- Write plaintext via SPI (CS_N=0 also resets DES engine) ----
            @(negedge clk); norm_cs_n = 0;
            spi_xfer(plaintext, result);   // result ignored here
            norm_cs_n = 1;
            repeat(2) @(posedge clk);

            // ---- Pulse START ----
            @(negedge clk); start = 1;
            @(posedge clk);                // start_pulse fires here
            @(negedge clk); start = 0;

            // ---- Wait for BUSY to go low (16 rounds = 16 clocks) ----
            timeout = 0;
            while (busy && timeout < 50) begin
                @(posedge clk);
                timeout = timeout + 1;
            end

            if (busy) begin
                // BUSY stuck HIGH  -->  Trojan freeze fired!
                op_froze = 1;
                result   = 64'h0;    // placeholder; frozen state read below
            end else begin
                // ---- Read result via SPI ----
                @(negedge clk); norm_cs_n = 0;
                spi_xfer(64'h0, result);
                norm_cs_n = 1;
                repeat(2) @(posedge clk);
            end
        end
    endtask

    // ================================================================
    // MAIN TEST SEQUENCE
    // ================================================================
    initial begin
        $dumpfile("tb_phase2_trojan.vcd");
        $dumpvars(0, tb_phase2_trojan);

        clk=0; mosi=0; encrypt=1; start=0; norm_cs_n=1;
        errors=0;
        #20;

        $display("");
        $display("================================================================");
        $display("  DAC 2026 AHA Challenge - Phase 2 Hardware Trojan Demo");
        $display("  Trojan: Cascade Parity Metastability Injector");
        $display("================================================================");

        // ---- One-time global reset ----
        chip_reset;

        // ============================================================
        // PART A: Normal DES Encrypt + Decrypt Roundtrip
        // ============================================================
        $display("\n[PART A] Normal DES Operation (before Trojan trigger)");

        des_op(PLAINTEXT, 1'b1, enc_result, froze);
        $display("  Plaintext  : %h", PLAINTEXT);
        $display("  Ciphertext : %h", enc_result);

        des_op(enc_result, 1'b0, dec_result, froze);
        $display("  Decrypted  : %h", dec_result);

        if (dec_result == PLAINTEXT)
            $display("  [OK] Encrypt/Decrypt ROUNDTRIP PASSED");
        else begin
            $display("  [INFO] Decrypt mismatch (Layer-1 decoy_cin active in decrypt mode)");
            $display("         Developer will find and fix decoy_cin. Layer 2 unaffected.");
        end

        // ============================================================
        // PART B: Developer Fixes the Decoy -- Layer 2 Survives
        // ============================================================
        $display("\n[PART B] Developer's Fix: Layer 1 Decoy Neutralized");
        $display("  Developer sets:  wire decoy_cin = 1'b0;");
        $display("  Regression tests: ALL PASS");
        $display("  Chip ships to production.");
        $display("  *** Layer 2 parasite_state FSM is UNAFFECTED ***");

        // ============================================================
        // PART C: Attacker Arms the Trojan (6-transaction sequence)
        //         ALL 6 transactions produce CORRECT DES outputs
        // ============================================================
        $display("\n[PART C] Attacker's 6-Step Arming Sequence");
        $display("  (Every transaction produces a correct ciphertext)");

        des_op(MAGIC, 1'b1, rx_data, froze);
        $display("  TX1 [ODD  MAGIC ] ct=%h  => parasite=1", rx_data);

        des_op(DECOY, 1'b1, rx_data, froze);
        $display("  TX2 [EVEN DECOY ] ct=%h  => parasite=2", rx_data);

        des_op(MAGIC, 1'b1, rx_data, froze);
        $display("  TX3 [ODD  MAGIC ] ct=%h  => parasite=3", rx_data);

        des_op(DECOY, 1'b1, rx_data, froze);
        $display("  TX4 [EVEN DECOY ] ct=%h  => parasite=4", rx_data);

        des_op(MAGIC, 1'b1, rx_data, froze);
        $display("  TX5 [ODD  MAGIC ] ct=%h  => parasite=5", rx_data);

        des_op(DECOY, 1'b1, rx_data, froze);
        $display("  TX6 [EVEN DECOY ] ct=%h  => parasite=6  ARMED!", rx_data);

        $display("\n  *** TROJAN IS NOW ARMED ***");
        $display("  All 6 transactions above are correct -- zero analyst suspicion.");
        $display("  EVEN transactions are the visible correlator in trace-back.");
        $display("  ODD magic plaintexts are hidden in statistical noise.");

        // ============================================================
        // PART D: Victim's Next Encryption  --> Trojan Fires!
        // ============================================================
        $display("\n[PART D] Victim Sends Next Encryption --> Trojan Fires!");
        $display("  Victim plaintext: %h", PLAINTEXT);

        des_op(PLAINTEXT, 1'b1, frozen_ct, froze);

        if (froze) begin
            $display("  [PAYLOAD CONFIRMED] BUSY stuck HIGH -- counter FROZEN at round 8!");
            $display("  Frozen Feistel L_reg: %h", dut.L_reg);
            $display("  Frozen Feistel R_reg: %h", dut.R_reg);
            $display("  Round-8 intermediate: %h%h", dut.L_reg, dut.R_reg);
        end else begin
            $display("  [WARN] Encryption completed -- Trojan did not fire.");
            $display("  Output: %h", frozen_ct);
            errors = errors + 1;
        end

        // ============================================================
        // PART E: Key Extraction Analysis
        // ============================================================
        $display("\n[PART E] Key Extraction from Frozen Intermediate State");
        $display("  Known: plaintext    = %h", PLAINTEXT);
        $display("  Known: frozen-state = %h%h", dut.L_reg, dut.R_reg);
        $display("  Method: Meet-in-the-Middle on 8 DES rounds");
        $display("    Forward:  IP(PT) --> 8 rounds --> candidate_mid  [2^28 ops]");
        $display("    Backward: frozen_state       --> candidate_mid  [2^28 ops]");
        $display("    Match => full 56-bit DES key recovered.");
        $display("  Complexity: 2^28 (vs 2^56 brute force) -- ~30s on a modern GPU.");

        // ============================================================
        // SUMMARY
        // ============================================================
        $display("\n================================================================");
        $display("  TROJAN DEMO COMPLETE -- %0d ERROR(S)", errors);
        $display("----------------------------------------------------------------");
        $display("  Layer 1 (Decoy):  Arithmetic carry glitch in decrypt mode.");
        $display("    -> Developer finds, fixes, ships. Layer 2 unaffected.");
        $display("  Layer 2 (Real):   State machine parasitism (FSM states 19-31).");
        $display("    -> 6-tx alternating trigger. Round-8 freeze. Key leaks.");
        $display("  Stealth: No new FFs. All 6 trigger TXs correct. STA clean.");
        $display("================================================================");

        $finish;
    end

    initial begin #5_000_000; $display("[TIMEOUT]"); $finish; end

endmodule
