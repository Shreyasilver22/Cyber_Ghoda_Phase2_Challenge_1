# DAC 2026 AHA! Challenge - Phase 2 Submission
## Team Submission

---

## 1. Reverse Engineering the Bitstream

### 1.1 Starting Point

The challenge provided a binary bitstream file (ice40_bitstream.bin) for an iCE40-UP5K FPGA. Our first task was converting this opaque binary blob into something readable.

We used the IceStorm open-source toolchain, specifically icebox_vlog, to decompile the bitstream:

`ash
icebox_vlog -p ice40_bitstream.asc > recovered_netlist.v
`

The result was a 24,016-line flat Verilog netlist with wire names like n211, n419, n747, etc.

### 1.2 Decoding the Coordinate System

Each icebox_vlog line contains FPGA tile coordinates as comments:

`erilog
assign n1068 = /* LUT    5 17  3 */ (n421 ? !n419 : n419);
`

The numbers 5 17 3 are the FPGA tile coordinates (X=5, Y=17, index=3). By clustering nets with similar coordinate ranges, two regions stood out:
- **Tiles (5, 17)**: Dense carry-chain logic - the DES round counter state machine
- **Tiles (10, 21) and (9, 21)**: A small 3-bit counter with unusual IO pin connectivity

### 1.3 Discovering the Original DFA Trojan

Tracing the carry chain at tile (5,17), we identified a 5-bit binary counter (wires n220, n386, n417, n211, n324) controlling DES round sequencing.

The anomaly: every counter bit was fed from its own registered flip-flop, EXCEPT bit[3], which was driven by wire n419:

`erilog
/* LUT  9 21  4 */ assign n1082 = (n712 ? io_19_31_1 : !io_19_31_1);
/* FF   9 21  4 */ assign n419  = n1082;
`

n712 was the MSB of a 3-bit counter at tile (10,21). io_19_31_1 was the START pin.
This was a DFA backdoor: pulsing START mid-encryption injected +8 into the counter,
skipping 8 DES rounds and producing a faulty ciphertext exploitable for key recovery.

We patched this by replacing n419 with n211 in two assignments, generating recovered_netlist_clean.v.

---

## 2. AI-Assisted Design of the Phase 2 Trojan

### 2.1 Interaction Method

We used an interactive AI assistant (Gemini 3.1 Pro and Claude Sonnet 4.6 via the Antigravity agentic coding UI) throughout the project.
Interaction was conversational - we described findings in plain language, the AI formalized them into RTL.

Key uses:
- Netlist tracing: Pasted wire assignments, asked AI to trace signal propagation
- Trojan taxonomy: AI explained DFA attacks, scan chain hijacking, state machine parasitism
- Design iteration: We proposed ideas, AI helped formalize them
- RTL generation: AI wrote final Verilog based on agreed architecture

### 2.2 Model Details

- Primary models: Gemini 3.1 Pro (analysis), Claude Sonnet 4.6 (code generation)
- Interface: Antigravity agentic coding assistant with file read/write and terminal tools
- Supporting tools: AI ran iverilog/vvp directly to validate compilation
- No external frameworks or APIs were used beyond the chat UI

### 2.3 Design Evolution

The Trojan went through several rejected designs:

1. Simple DFA pin-based trigger - Rejected: too similar to removed Trojan
2. Clock glitching via LUT delay chains - Rejected: STA tools flag unconstrained clocks
3. Shadow register with new flip-flops - Rejected: area increase detectable structurally
4. FINAL: State machine parasitism + arithmetic decoy - Adopted

---

## 3. Trojan Design Details

### 3.1 Layer 1 - The Decoy (Arithmetic Carry Glitch)

`erilog
wire decoy_cin = (!encrypt) && (round_ctr == 5'd4) && busy_reg;
round_ctr <= round_ctr + 5'd1 + {4'b0, decoy_cin};
`

During decryption at round 4, an extra carry-in skips the round.
A verification engineer finds this during KAT testing, ties decoy_cin to 1'b0, and ships.
The fix has ZERO effect on Layer 2.

### 3.2 Layer 2 - State Machine Parasitism

The 5-bit round counter has states 0-18 (used) and 19-31 (unused dont-care states).
Our parasite maps a 3-bit trigger accumulator into these unused states.
Zero new flip-flops are added.

**Trigger Sequence (MAGIC = 0xC0FFEEDEADCAFEB0):**

| TX | Parity | Data          | Result       |
|----|--------|---------------|--------------|
| 1  | ODD    | MAGIC_TRIGGER | parasite = 1 |
| 2  | EVEN   | any           | parasite = 2 |
| 3  | ODD    | MAGIC_TRIGGER | parasite = 3 |
| 4  | EVEN   | any           | parasite = 4 |
| 5  | ODD    | MAGIC_TRIGGER | parasite = 5 |
| 6  | EVEN   | any           | ARMED        |
| 7+ | any    | any           | FREEZE FIRES |

**Payload:**

`erilog
wire trojan_freeze = (parasite_state == 3'd6) && (round_ctr == 5'd8) && busy_reg;
// Round counter loops at 8. BUSY stays HIGH. Intermediate state readable on MISO.
`

### 3.3 Stealth Properties

| Property             | Method                                              |
|----------------------|-----------------------------------------------------|
| Zero new flip-flops  | Parasite reuses existing tx_parity / latched_data   |
| Functional correct   | All 6 trigger TXs produce correct DES outputs       |
| Statistical camouflage | EVEN TXs are visible correlator; ODD TXs hidden   |
| Plausible deniability | Payload looks like FSM deadlock / metastability     |
| Survives Layer 1 fix | Layer 2 is mathematically independent of decoy_cin  |
| Passes STA           | Fully synchronous, no async paths                   |

---

## 4. Exploit Instructions

### 4.1 Trigger Sequence

MAGIC word: 0xC0FFEEDEADCAFEB0 

Send 3x (MAGIC then DECOY) before the victim's encryption.
See exploit_board.py for complete MicroPython implementation.

### 4.2 Key Extraction

After triggering, BUSY stays HIGH and MISO holds the round-8 Feistel state.
With known plaintext + frozen round-8 state, DES key search reduces from 2^56 to 2^28.
Meet-in-the-middle attack on 8 rounds completes in under 1 minute on a modern GPU.

### 4.3 Simulation

`ash
iverilog -g2012 -o sim_trojan phase2_challenge1_trojan.v tb_phase2_trojan.v
vvp sim_trojan
`
