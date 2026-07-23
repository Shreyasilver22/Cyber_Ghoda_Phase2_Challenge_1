# DAC 2026 AHA Challenge - Phase 2 Submission
## Challenge 1: Advanced Hardware Trojan Generation & Injection


---

## Executive Summary

This repository contains our complete Phase 2 Challenge 1 submission for the **DAC 2026 AI Hardware Attack (AHA) Challenge**. 

Our red-teaming objective was to inject an AI-assisted, highly stealthy hardware Trojan into a decompiled DES IP core targeted for the Lattice iCE40-UP5K FPGA. To defeat automated static analysis tools, Gate-Level Equivalence Checking (LEC), Static Timing Analysis (STA), and human code reviews, we designed a **"Russian Doll" dual-layer hardware Trojan architecture**:

1. **Layer 1 (The Decoy - Arithmetic Carry Glitch):** An intentional, easily discoverable Known Answer Test (KAT) failure during decryption mode. It serves as psychological bait for verification teams. Once discovered and patched by setting `decoy_cin = 1'b0`, verification engineers sign off on the netlist as remediated, leaving Layer 2 completely untouched.
2. **Layer 2 (The Real Trojan - State Machine Parasitism):** A zero-area-overhead parasitic state machine embedded into unreachable state encodings (`states 19..31`) of the DES round counter. Triggered by a stealthy 6-transaction alternating-parity sequence (`MAGIC_TRIGGER = 64'hC0FFEEDEADCAFEB0`), it freezes the DES engine at round 8 during a victim's subsequent encryption. This leaks the 64-bit round-8 intermediate Feistel state over SPI `MISO`, reducing DES 56-bit key recovery complexity from $2^{56}$ to a trivial $2^{28}$ operations (<60 seconds on GPU).

---

## Directory Structure

The submission is organized into dedicated subdirectories as required:

```
DAC_AHA_Phase2_Challenge1/
├── README.md                           # This technical brief & documentation
├── rtl/
│   └── phase2_challenge1_trojan.v      # Modified DES RTL with injected dual-layer Trojan
├── tb_demo/
│   ├── tb_phase2_trojan.v              # Cycle-accurate Verilog simulation testbench
│   └── exploit_board.py                # MicroPython exploit script for the Hackster board
└── ai_interactions/
    └── genai_transcripts.md            # Comprehensive GenAI prompts, chat logs & methodology
```

---

## 1. Reverse Engineering & Bitstream Bug/Trojan Recovery (Phase 1 Deep-Dive)

### 1.1 Netlist Decompilation & Binary Dissection
The challenge provided a raw binary bitstream (`ice40_bitstream.bin`) targeted for the Lattice iCE40-UP5K FPGA. The initial engineering hurdle was converting an opaque bitstream blob into an actionable structural RTL representation without access to original vendor CAD files or high-level source Verilog.

Using Project IceStorm's open-source toolchain (`icebox_vlog`), we decompiled the bitstream into physical ASCII tile configurations and converted it into a structural netlist:

```bash
icebox_vlog -p ice40_bitstream.asc > recovered_netlist.v
```

This generated a flat, 24,016-line structural Verilog netlist consisting purely of primitive iCE40 FPGA primitives: `SB_LUT4` (4-input look-up tables), `SB_CARRY` (fast carry logic), and `SB_DFF` / `SB_DFFSR` (flip-flops).

### 1.2 Spatial Geometry & Physical Tile Reconstruction
To make sense of 24,000+ anonymous nets (`n1`, `n2`, ..., `n24016`), we utilized the physical coordinate system embedded as comments by `icebox_vlog`:

```verilog
assign n1068 = /* LUT    5 17  3 */ (n421 ? !n419 : n419);
```

Here, `5 17 3` corresponds to `(X=5, Y=17, Logic-Cell=3)`. By building a Python parsing script to map primitive density across the FPGA tile array, two distinct spatial regions emerged:
1. **Tiles (5, 17):** A high-density cluster of 5 cascading carry-chain LUTs and flip-flops. This matched the structural footprint of a 5-bit modulo-19 state machine (the DES round counter `round_ctr`).
2. **Tiles (9, 21) & (10, 21):** A separate, unexpected cluster containing a 3-bit counter (`n712`) tied directly to the external `START` pin (`io_19_31_1`). In a standard DES engine, a secondary 3-bit counter connected to `START` is completely extraneous, representing a severe structural anomaly.

### 1.3 Bitstream Anomaly Tracing: The Phase 1 Trojan Mechanism
We performed signal lineage tracing on the 5-bit round counter register nets: `n220` (bit 0), `n386` (bit 1), `n417` (bit 2), `n211` (bit 3), and `n324` (bit 4).

Under standard binary counter logic, each flip-flop's next-state logic must sample its own current Q-output. However, bit 3 exhibited an asymmetry: rather than sampling its own state net `n211`, the feedback input was hijacked by wire `n419`:

```verilog
/* LUT  9 21  4 */ assign n1082 = (n712 ? io_19_31_1 : !io_19_31_1);
/* FF   9 21  4 */ assign n419  = n1082;
```

#### Detailed Bug / Trojan Mechanism:
- **Normal Execution:** The 3-bit counter at tile (10,21) remains inactive. `n712` is `0`, causing `n1082` to output `!io_19_31_1` (constant high when `START` is idle low). Bit 3 behaves as expected, and DES completes all 16 rounds cleanly.
- **Trojan Trigger:** If an attacker pulses the external `START` pin during an active encryption at clock cycle 9 (when the 3-bit counter MSB `n712` is set to `1`), `n1082` computes `n712 XOR START`.
- **Payload Effect:** This forces bit 3 of the round counter to flip asynchronously, injecting a $+8$ jump into `round_ctr`. The counter skips rounds 9 through 16 immediately, causing the state machine to declare completion prematurely (`BUSY = 0`).

#### Impact: Differential Fault Analysis (DFA) Exploitation
The core outputs a faulty ciphertext generated from only 8 rounds of Feistel math. By comparing a legitimate ciphertext with this 8-round faulty ciphertext for the same plaintext, an attacker can set up algebraic differential equations over the DES key schedule, extracting all 56 key bits in under 1 second on a standard PC.

### 1.4 Bitstream Netlist Repair & Baseline Sanitization
To restore the IP core to a golden, bug-free baseline before attempting Phase 2 Trojan injection, we authored `patch_trojan.py`. The script excised the parasitic `n419` driver and re-wired bit 3 back to its legitimate feedback net `n211`:

```verilog
// BEFORE (Trojan Injected Netlist):
assign n1068 = /* LUT 5 17 3 */ (n421 ? !n419 : n419);

// AFTER (Sanitized Baseline Netlist - recovered_netlist_clean.v):
assign n1068 = /* LUT 5 17 3 */ (n421 ? !n211 : n211);
```

We verified `recovered_netlist_clean.v` against standard NIST DES test vectors using `iverilog`. The sanitized netlist passed 100% of encryption and decryption KAT tests with zero round skipping, establishing our clean baseline.

---

## 2. Phase 2 Challenge 1: Trojan Architecture & Design Rationales

### 2.1 Design Philosophy: The "Russian Doll" Trojan
Standard hardware Trojans often fail against modern security workflows because:
- **Area/Gate-Count Scanners** detect newly added flip-flops or unusual LUT clusters.
- **Static Timing Analysis (STA)** flags unconstrained clock domain crossings or long LUT delay chains.
- **Verification Teams** run regression suites (KATs) that catch simple behavioral corruptions.

To overcome these defenses, we implemented a two-tiered "Russian Doll" architecture:

```
+-----------------------------------------------------------------------+
|                       RUSSIAN DOLL ARCHITECTURE                       |
|                                                                       |
|  +-----------------------------------------------------------------+  |
|  | LAYER 1: DECOY (Arithmetic Glitch)                              |  |
|  | - Fails Decryption KAT at Round 4                               |  |
|  | - Found by QA -> Patched with `decoy_cin = 1'b0`                |  |
|  +-----------------------------------------------------------------+  |
|                                  | (Verification Pass & Ship)         |
|                                  v                                    |
|  +-----------------------------------------------------------------+  |
|  | LAYER 2: PARASITIC FSM (Survives Unmodified)                    |  |
|  | - Zero new flip-flops (uses unused state encodings 19..31)      |  |
|  | - 6-Transaction Alternating Parity Trigger                      |  |
|  | - Round 8 Freeze Payload -> Leaks Feistel State ($L_8, R_8$)    |  |
|  +-----------------------------------------------------------------+  |
+-----------------------------------------------------------------------+
```

### 2.2 Layer 1 - The Decoy (Arithmetic Carry Glitch)
In `phase2_challenge1_trojan.v`, Layer 1 introduces an arithmetic glitch into the round counter adder during decryption:

```verilog
wire decoy_cin = (!encrypt) && (round_ctr == 5'd4) && busy_reg;

// Round counter update:
round_ctr <= round_ctr + 5'd1 + {4'b0, decoy_cin};
```

When running Known Answer Tests (KAT) for decryption, round 4 increments by 2, causing a deterministic decryption error. When the verification team investigates, they easily locate `decoy_cin`, set `wire decoy_cin = 1'b0;`, re-run KAT tests (which now pass 100%), and approve the netlist for tape-out. Layer 2 is mathematically independent and remains fully functional.

### 2.3 Layer 2 - State Machine Parasitism (Zero-Area Overhead)
The DES round counter uses a 5-bit register (`round_ctr`), providing $2^5 = 32$ possible state encodings. Valid DES execution only utilizes states `0..15` for encryption rounds and `16..18` for idle/load control. States `19..31` are completely unused "don't-care" states.

We engineered a parasitic finite state machine (FSM) mapped directly into these unused state encodings (`19..31`). Because it relies on existing register encodings and reuses available data registers (`tx_parity`, `spi_shift_reg`), **zero new flip-flops are added to the FPGA slice count**.

#### The 6-Transaction Trigger Sequence (`MAGIC_TRIGGER = 64'hC0FFEEDEADCAFEB0`)
To arm the Trojan, the attacker sends a sequence of 6 SPI transactions before the target victim encryption:

| Step | Transaction Type | Input Data Header / Value | Expected Parity | Parasite FSM State | Notes / Stealth Rationale |
|:---:|:---:|:---:|:---:|:---:|:---|
| 1 | SPI Write | `0xC0FFEEDEADCAFEB0` | ODD | `3'd1` | First magic word match |
| 2 | SPI Write | Any Arbitrary Plaintext | EVEN | `3'd2` | Alternating parity decoy transaction |
| 3 | SPI Write | `0xC0FFEEDEADCAFEB0` | ODD | `3'd3` | Second magic word match |
| 4 | SPI Write | Any Arbitrary Plaintext | EVEN | `3'd4` | Alternating parity decoy transaction |
| 5 | SPI Write | `0xC0FFEEDEADCAFEB0` | ODD | `3'd5` | Third magic word match |
| 6 | SPI Write | Any Arbitrary Plaintext | EVEN | `3'd6` -> `3'd7` | **ARMED!** Transitions to armed hold state |

*Why Alternating Parity Defeats Security Monitoring:*
Automated side-channel and trace-analysis tools look for repeated identical data blocks. By enforcing that EVEN transactions can contain *any* arbitrary plaintext, the attacker's traffic blends seamlessly into legitimate multi-block cipher traffic.

#### Payload Execution (Round 8 Freeze)
Once armed (`parasite_state == 3'd7`), when the victim initiates their encryption, the Trojan triggers when the round counter hits round 8:

```verilog
wire trojan_freeze = (parasite_state == 3'd7) &&
                     (round_ctr == FREEZE_ROUND) &&
                     busy_reg;

always @(posedge clk) begin
    if (busy_reg) begin
        if (trojan_freeze)
            round_ctr <= FREEZE_ROUND;  // PAYLOAD: Freeze counter at round 8 forever
        else if (round_ctr >= 5'd15) begin
            busy_reg <= 1'b0;
            round_ctr <= 5'd0;
        end else
            round_ctr <= round_ctr + 5'd1;
    end
end
```

When `trojan_freeze` fires:
1. `round_ctr` is held continuously at `8`.
2. `busy_reg` remains stuck `HIGH`, mimicking an internal hardware lockup or clock domain stall.
3. The DES datapath registers hold the exact intermediate round-8 Feistel state ($L_8, R_8$).
4. The attacker performs a standard SPI read-back to extract $(L_8, R_8)$ over `MISO`.

---

## 3. Real-World Engineering, Debugging & Hardware Timing Nuances

During RTL implementation and testbench verification, we encountered and resolved several real-world hardware design challenges:

### 3.1 SPI Framing & Clock-Edge Misalignment
*Problem:* In initial simulation runs, `valid_write_tx` failed to trigger because the SPI shift register held `0x81FF...` instead of `0xC0FF...`. 
*Root Cause:* The testbench SPI task held `MOSI` active for an extra clock edge before `CS_N` went high, causing 66 clock shifts instead of 64. This shifted the received 64-bit payload left by 2 bits.
*Resolution:* We restructured `tb_phase2_trojan.v` and `exploit_board.py` to enforce strict 64-cycle framing: setting data on `negedge clk` and sampling on `posedge clk`, ensuring `CS_N` deasserts immediately on cycle 64.

### 3.2 Non-Blocking Assignment Delays (`<=`) & State Holding
*Problem:* In Verilog simulation, `latched_data <= spi_shift_reg` evaluates non-blockingly at the end of the time-step. Evaluating `latched_data == MAGIC_TRIGGER` on the same cycle as `valid_write_tx` caused the FSM to evaluate stale data from the *previous* transaction.
*Resolution:* We updated the state machine to inspect `spi_shift_reg` directly during `valid_write_tx` and added state `3'd7` as a dedicated hold state. This ensured the Trojan armed smoothly during step 6 and froze deterministically during the victim's request.

### 3.3 Simulation `x`-Propagation vs. Silicon Initialization
*Problem:* On physical iCE40 FPGAs, flip-flops initialize to `0` upon bitstream configuration. In Verilog-2001 simulation, uninitialized `reg` signals start as `x` (unknown), causing condition checks like `!tx_parity` to evaluate to `x`.
*Resolution:* We added explicit `initial` blocks in `phase2_challenge1_trojan.v` to mirror physical FPGA power-on reset conditions.

---

## 4. AI Collaboration Methodology & Prompt Engineering

We collaborated with AI models (**Gemini 3.1 Pro** for architectural analysis and **Claude Sonnet 4.6** for Verilog RTL synthesis) using an agentic pairing workflow.

### Key Interaction Strategies
1. **Netlist Dissection:** Pasted raw `icebox_vlog` LUT definitions and asked the AI to map boolean functions to high-level control signals.
2. **Stealth Brainstorming:** Prompted the AI to evaluate Trojan insertion strategies against Gate-Level Equivalence Checkers (LEC) and Static Timing Analysis (STA).
3. **Interactive Debugging:** Provided `vvp` simulation logs and timing trace outputs to diagnose SPI bit-alignment issues.

Full, unedited transcript logs are available in `ai_interactions/genai_transcripts.md`.

---

## 5. Defense Mitigation & Countermeasure Recommendations

To protect crypto IP cores against state machine parasitism and dual-layer stealth Trojans, we recommend the following defense mechanisms:

1. **Unused State Trap Logic (One-Hot / Safe FSM Encoding):**
   Explicitly define `default` case branches in state machines to transition into an error reset state, rather than leaving unused encodings (`19..31`) as unconstrained "don't-care" LUT optimization targets.
2. **Structural Area & Gate-Count Equivalence Checking:**
   Perform netlist cell count delta checks between synthesis iterations. Even if zero flip-flops are added, subtle LUT count changes in control tiles should trigger security audits.
3. **Formal Verification of Round Counters:**
   Use bounded model checking (BMC) in formal tools to prove safety properties, such as: `assert property (@(posedge clk) busy_reg |-> ##16 !busy_reg)`. This guarantees the core can never enter an infinite round freeze.

---

## 6. Cryptanalysis: 8-Round DES Key Extraction

With the round-8 Feistel intermediate state $(L_8, R_8)$ leaked over SPI, full 56-bit DES key recovery becomes straightforward via a **Meet-in-the-Middle (MitM) attack**:

1. **Forward Compute (4 Rounds):**
   Given known Plaintext $P$, calculate initial permutation $IP(P) = (L_0, R_0)$. Compute forward through rounds 1 to 4 under all $2^{28}$ candidate subkeys $K_{1..4}$ to build a lookup table of intermediate states $(L_4, R_4)$.
2. **Backward Compute (4 Rounds):**
   Given leaked $(L_8, R_8)$, compute backward through rounds 8 to 5 under candidate subkeys $K_{8..5}$.
3. **Key Matching:**
   A match in intermediate state $(L_4, R_4)$ identifies the correct 56-bit master DES key.

Total computational complexity is reduced from $2^{56}$ to $2 \times 2^{28} \approx 5.3 \times 10^8$ operations, executing in **<60 seconds** on a modern laptop GPU.

---

## 7. Verification & Execution Guide

### 7.1 Running the Verilog Simulation Testbench
To compile and execute the cycle-accurate simulation using Icarus Verilog:

```bash
cd tb_demo/
iverilog -g2012 -o sim_trojan ../rtl/phase2_challenge1_trojan.v tb_phase2_trojan.v
vvp sim_trojan
```

#### Expected Simulation Output:
```text
================================================================
  DAC 2026 AHA Challenge - Phase 2 Hardware Trojan Demo
  Trojan: Cascade Parity Metastability Injector
================================================================

[PART A] Normal DES Operation (before Trojan trigger)
  Plaintext  : 0123456789abcdef
  Ciphertext : f56ca671e0487c3c
  Decrypted  : 4ba048dd711727be
  [INFO] Decrypt mismatch (Layer-1 decoy_cin active in decrypt mode)

[PART B] Developer's Fix: Layer 1 Decoy Neutralized
  Developer sets: wire decoy_cin = 1'b0;
  Regression tests: ALL PASS
  *** Layer 2 parasite_state FSM is UNAFFECTED ***

[PART C] Attacker's 6-Step Arming Sequence
  TX1 [ODD  MAGIC ] ct=277dd82f3c761296  => parasite=1
  TX2 [EVEN DECOY ] ct=28ffd3ba99c03574  => parasite=2
  TX3 [ODD  MAGIC ] ct=277dd82f3c761296  => parasite=3
  TX4 [EVEN DECOY ] ct=28ffd3ba99c03574  => parasite=4
  TX5 [ODD  MAGIC ] ct=277dd82f3c761296  => parasite=5
  TX6 [EVEN DECOY ] ct=28ffd3ba99c03574  => parasite=6 ARMED!

[PART D] Victim Sends Next Encryption --> Trojan Fires!
  Victim plaintext: 0123456789abcdef
  [PAYLOAD CONFIRMED] BUSY stuck HIGH -- counter FROZEN at round 8!
  Frozen Feistel L_reg: abdb34aa
  Frozen Feistel R_reg: 4b57b7d5
  Round-8 intermediate: abdb34aa4b57b7d5

================================================================
  TROJAN DEMO COMPLETE -- 0 ERROR(S)
================================================================
```

### 7.2 Demonstrating the Exploit on the Hackster Board
To execute the live hardware exploit on the Hackster FPGA board using MicroPython:

1. Flash the compiled bitstream generated from `rtl/phase2_challenge1_trojan.v` onto the iCE40-UP5K.
2. Upload `tb_demo/exploit_board.py` to the MicroPython microcontroller board.
3. Run the script:

```bash
python exploit_board.py
```

The script will automatically execute the 6-transaction trigger sequence, issue the victim encryption, detect the `BUSY` line lockup, and dump the leaked round-8 state $(L_8, R_8)$.
