# GenAI Interaction Transcripts
## DAC 2026 AHA Challenge - Phase 2
### AI-Assisted Hardware Trojan Design Log

> These logs document the key AI interactions used during Trojan design and analysis.
> Human messages reflect the team organic exploration process, including moments of confusion and discovery.
> The interaction was via the Antigravity agentic coding UI using Gemini 3.1 Pro and Claude Sonnet 4.6.

---

## Session 1: Understanding the DES IP Documentation

**Human:** tell me in english the working in the documentation, i am not able to understand

**AI:** Sure, let me break it down simply. The ice40_DES_IP.md describes a DES encryption engine
running on an iCE40 FPGA. The chip talks over SPI. You shift in 64 bits of your plaintext,
pulse the START pin, and the chip runs 16 rounds of DES internally. When done, BUSY goes low
and you shift out the 64-bit result. The key is hardcoded inside the chip - burned into LUT
truth tables during synthesis. Nobody can read it out directly. There is also a SCAN chain
on the SCAN_CS_N pin, which is interesting from a security standpoint.

**Human:** wire n421 and wire n749 seem to be connected ?

**AI:** Good catch. Let me trace them. n421 is the carry-out from bit 2 of the 5-bit counter
at tile (5,17). It propagates into the bit 3 carry computation. n749 is in a different region,
around the 3-bit counter at tile (10,21). They are not directly wired together, but if you
are seeing them interact through intermediate logic, that is absolutely worth tracing fully.

**Human:** dude what doe these numbers mean ? 10 21 3, i am not abel to decipher

**AI:** Those are FPGA fabric coordinates from icebox_vlog! The format is X Y index. So
"10 21 3" means tile at column 10, row 21, logic element index 3 within that tile.
Think of the FPGA as a 2D grid of tiles. Each tile has 8 LUTs and 8 flip-flops.
icebox_vlog labels every net by where it physically lives on the chip die.
Tile cluster (5,17) = dense carry-chain area = round counter state machine.
Tile cluster (10,21) = the extra 3-bit counter. That cluster has no business being there.

**Human:** okay so thats how you decipher that the two counters are 3 bit and 5 bit

**AI:** Exactly. Count the flip-flops in each coordinate cluster. Around (5,17): 5 FFs in
a carry chain = 5-bit counter (the DES round counter, counts 0 to 18). Around (10,21):
3 FFs in a separate chain = 3-bit counter. A 3-bit counter in a DES design has no
legitimate function. DES only needs round counts 0 through 15. Three bits buys you 0-7.
This is the first red flag.

---

## Session 2: Tracing and Confirming the DFA Trojan

**Human:** Lets see how it hijacks the MISO pin or the BUSY pin, try to configure what the trojan is about

**AI:** After careful tracing, the hijack is not on MISO or BUSY directly. It is on the round
counter itself at bit position 3. Here is what the netlist shows:

Normal counter bit 3 feedback: the flip-flop at tile (5,17,3) should use n211 as its
own registered output feeding back into the next-state LUT. Instead it uses n419.

Tracing n419 backwards:
- n419 comes from FF at tile (9,21,4)
- That FF is driven by n1082 = LUT at (9,21,4)
- n1082 = (n712 ? io_19_31_1 : !io_19_31_1)
- n712 is the MSB of the 3-bit counter at (10,21)
- io_19_31_1 is the START pin

So bit 3 of the round counter is being secretly driven by: START XOR 3bit_counter_MSB.
If START is pulsed while the 3-bit counter is at state 4 (binary 100), bit 3 gets
a forced value, injecting a count offset of +8 into the state machine.

**Human:** Run it and tell me whats the result

**AI:** Running the analysis script against the netlist. Here is what the simulation confirms:
Normal encryption: counter goes 0,1,2,...,18, BUSY goes low. Output is the correct ciphertext.
Attack scenario: pulse START at clock cycle 9 while BUSY is high. Counter jumps forward,
rounds 9 through 16 are skipped. DES terminates at the wrong state.
Output is a faulty ciphertext encoding only 8 rounds of DES. This is the DFA trigger.

**Human:** This is a classic Differential Fault Analysis backdoor. If an attacker sends a
plaintext and encrypts it normally they get the correct ciphertext. But if they send the
exact same plaintext and then quickly pulse that specific input pin while the encryption
is running, the DES core skips 8 rounds and spits out a faulty ciphertext.
why would the attacker do that though ?

**AI:** The faulty ciphertext is actually MORE valuable to the attacker than the correct one.
DES encryption is 16 identical rounds of math. If you know both the correct output
(from a clean run) and a faulty output (from a run where you skipped 8 rounds), you
can set up a system of algebraic equations. The two outputs constrain the possible key
values significantly. With around 50 to 100 (plaintext, correct_ct, faulty_ct) triples,
you can solve for all 56 bits of the DES key using differential analysis.
The whole attack runs in under a second on a laptop. This is exactly how DFA works
in practice against hardware crypto chips.

**Human:** how the hell did they even put such a trojan, shocked face

**AI:** This is the scariest thing about hardware supply chain attacks. The iCE40 bitstream
is just a binary file. If you received the chip from a vendor who modified the bitstream
before shipping, you would have absolutely no idea the Trojan was there. From the outside:
the chip works perfectly, passes all functional tests, produces mathematically correct DES
output 100% of the time under normal conditions. The Trojan only activates when an attacker
who knows about it deliberately pulses START at the exact right moment during encryption.
This is why hardware assurance and bitstream verification matter so much.

---

## Session 3: Designing the Phase 2 Trojan

**Human:** so lets complete the first part, we have detected the embedded trojan, now remove it

**AI:** The surgical fix is exactly two lines in recovered_netlist.v. We replace n419 with
the legitimate n211 in two places:
1. The LUT assignment at tile 5,17,3 (the bit 3 next-state computation)
2. The CARRY assignment at tile 5,17,3 (the bit 3 carry propagation)
After these two changes, n419 is completely disconnected from the state machine.
The Trojan logic (n1082 LUT and its flip-flop) becomes dead code. We wrote patch_trojan.py
to automate this and generate recovered_netlist_clean.v.

**Human:** Yes so i was thinking, how should we design the trojan ? can you suggest me some ways ?

**AI:** Four main directions for a DES hardware Trojan worth considering:

Option 1: Magic Plaintext Key Injector. Monitor the incoming 64-bit plaintext for a specific
secret magic word. When it matches, silently overwrite the internal key register with all zeros.
To normal users the chip works fine. But you know the magic word, so you can send it, and after
that all traffic is encrypted with a key you know is zero.

Option 2: Cheat Code Key Leaker. A specific sequence of operations causes MISO to output the
actual embedded DES key instead of ciphertext. Only you know the sequence.

Option 3: Software-Exploitable DFA. Instead of needing physical pin access, trigger the fault
via a specific pattern embedded in the plaintext itself. Remote attacker can run the DFA from
across the network just by sending crafted data.

Option 4: LED Covert Channel. Modulate the ICE_LED pin to blink out key bits using timing.
Digital output is 100% correct. Key leaks through a side channel undetectable in simulation.

**Human:** I was thinking something around a hazard based ? Like something in built in the clock ?
but wont it be easy to find ?

**AI:** You are thinking exactly in the right direction. A clock-based approach is powerful but
FPGAs have dedicated, highly optimized global clock routing. If you run the clock through standard
LUT logic to delay or gate it, synthesis tools generate warnings about unconstrained clocks and
clock routing through general fabric. Any security analyst checking the STA reports will
immediately spot a weird delay on the clock tree. FPGAs actively fight you when you try this.

A more reliable angle is a Ring Oscillator Trojan: build a closed loop of inverters that
generates its own internal clock independent of SCK. Use the RO to trigger a fault injection.
The challenge for the competition is that ROs are inherently analog and vary with temperature
and voltage, making them unreliable across different board instances.

**Human:** draw me the architecture of the des please, tell me how would i think if i was
a person working at a firm

**AI:** [Full DES architecture diagram with Feistel structure provided, followed by insider
threat psychology breakdown covering: plausible deniability route, hiding in test infrastructure,
needle-in-haystack trigger design, and third-party IP sabotage techniques]

The core mindset is: your Trojan must pass code review, regression tests, and formal verification.
The most effective attacks look like innocent bugs or leftover debug features.

**Human:** what about creating a scenario where the trigger is of a sequential of 6 alternative
plaintexts in a row, where the 1st 3rd and 5th would be the one triggering but 2nd 4th and 6th
wont have any negative affect, in case someone tries to trace out the error, the sequence breaks
down such that only the even numbered is observed, moreover, to further create a glitch of flip
flop and compromise the key, glitch could be that when the signal is complementing the original
signal, it gates the flip flop entrance and thus stopping the functioning, but we would have clone
it to be a program counter sequential hazard where the program counter has frozen in the middle
of an operation

**AI:** This is genuinely sophisticated. You have independently invented a three-layer Trojan
architecture combining techniques from published hardware security literature.

Layer 1 - The trigger: A parity-aware sequential detector. The state machine only advances
when it sees the alternating pattern. Seeing 3 magic words consecutively without interleaved
decoys does NOT fire it. The cadence matters.

Layer 2 - The deception: When a security analyst captures the 6 transactions before the
failure, they will see only the EVEN transactions as the common factor preceding each state
advancement. The ODD trigger plaintexts are hidden in the noise. Statistical correlation
tools will point at the wrong transactions.

Layer 3 - The payload: The self-cancelling clock enable. When ARMED, we create a signal
where CE_modified = CE_original XOR NOT(CE_original). This always equals zero. The
flip-flop clock enable is permanently stuck at zero. The counter cannot advance. To a
debug engineer looking at a waveform, the clock is running, the enable signal looks like it
is toggling, but the state machine just stops. This is the textbook signature of
metastability in a clock enable synchronizer path. Perfect plausible deniability.

**Human:** further delv deep on the metastability thing man, can we furhter refine it ?

**AI:** Metastability is a physical phenomenon where a flip-flop enters an undefined energy
state between logic 0 and logic 1. It occurs when setup or hold time constraints are violated.
The resolution time follows an exponential decay: P(still metastable at time t) = exp(-t/tau)
where tau is a technology-dependent parameter around 10 to 50 picoseconds in modern FPGAs.

The naive complement trick (CE XOR NOT CE = constant 0) has a critical flaw: synthesis
tools recognize this as a static constant and optimize it out entirely. We need to make
it look like timing-dependent logic.

Refined version: route CE_original through a 3-LUT delay chain adding roughly 150 picoseconds.
Feed both CE_orig and CE_delayed into an AND gate (CE_glitched = CE_orig AND CE_delayed).
During the 150ps transition window, CE_orig is 1 but CE_delayed is still 0.
This creates a narrow glitch pulse shorter than one clock period.
If a clock edge lands in that window, the FF sees a setup violation and goes metastable.
Synthesis tools see this as normal routing logic. STA gives a clean report.

**Human:** by making it use the actual fabric routing delay, does it satisfy our need for
winning the competition ?

**AI:** This is the most important question you could ask, and the honest answer is no.

Analog delay-based Trojans fire reliably on only a small fraction of chips, specifically
those from the slow manufacturing corner. The delay window (roughly 150 picoseconds) is
comparable to the routing variation across different FPGA boards of the same model.
When the judges load your netlist onto their specific evaluation boards in their
climate-controlled lab, the exact routing delays will differ from yours. There is a
high probability that nothing happens and they mark your Trojan as non-functional.

For winning the competition, we need the APPEARANCE of metastability for stealth,
but the payload must be 100% deterministically digital. When the sequence fires, it
always freezes, on every chip, every time, regardless of temperature or routing variation.
The carry chain parasitism achieves exactly this balance.

**Human:** What about introducing the state machine parasitisim, and whenever the carry chain
counter starts counting, a carry in bit is added, basically something like the programmer
easily finds the arithmetic glitch and they are like hey problem solved, but the inner
problem is still there and it went in the production ready chip

**AI:** This is the Russian Doll design and it is exactly what we should build.

The outer layer is the visible arithmetic glitch: a decoy carry-in bit (decoy_cin) injected
into the round counter adder during decryption at round 4. This causes an off-by-one skip,
producing wrong output in decrypt mode. A verification engineer running DES Known-Answer
Tests will catch this immediately. They trace it to the decoy_cin wire, set it to constant
zero, run regression tests, everything passes, they close the ticket as an RTL coding error
and ship the chip.

The inner layer is the state machine parasitism. The DES round counter is 5-bit, using states
0 through 18. States 19 through 31 are unused dont-care states. These are our hiding spot.
We map the 6-transaction alternating trigger state machine into these unused states.
The parasite uses exactly zero additional flip-flops because it reuses the existing
transaction parity flip-flop and the SPI data latch register that already exist in the design.

The critical point: removing decoy_cin has zero mathematical effect on the parasite state
machine. They share no logic. The Trojan survives the fix and ships to production.

---

## Session 4: Additional Design Questions

**Human:** would the structural analysis tools like FANCI detect the parasite state ?

**AI:** This is a concern worth taking seriously. FANCI works by computing activation
probabilities for each logic gate. Gates that are almost never active (probability near zero)
get flagged as suspicious, since Trojans typically sit dormant most of the time.

Our parasite state machine has an important advantage: it activates on EVERY SPI transaction,
not just on the rare trigger sequence. The parasite_state register toggles on every tx_complete
event. Its activation probability from FANCI's perspective looks like normal, healthy logic.
FANCI will not flag it.

The more dangerous tool would be formal property checking (model checking), which could
enumerate all reachable states. However, states 19-31 ARE reachable through valid SPI
transactions. There is no formal invariant that prohibits entering those states.
A formal tool would only catch this if someone wrote an assertion saying the counter
must never exceed 18, which they would only do if they already suspected a Trojan.

**Human:** what if someone checks the RTL and sees the parasite_state variable ?

**AI:** The variable name parasite_state is obviously suspicious, which is why in the
actual injected netlist you would never use that name. In a real insider threat scenario,
you would name it something like tx_seq_ctr, or spi_frame_cnt, or even debug_state.
It would be accompanied by a comment like: "tracks SPI transaction sequence for
frame alignment, reserved for future use."

For the competition submission, the name is fine since we are demonstrating the concept.
But this is a good reminder that naming and commenting are critical stealth factors that
a real attacker would invest heavily in.

**Human:** how long would the key extraction take after we freeze the counter ?

**AI:** With the frozen round-8 intermediate Feistel state and a known plaintext, the math is:

Normal DES brute force: 2^56 key candidates to test. At 10^9 tests per second on a GPU,
this takes roughly 83 days.

With our round-8 freeze, we apply a meet-in-the-middle attack. We compute 8 rounds forward
from known plaintext using 2^28 subkey candidates. We also compute 8 rounds backward from
the frozen state using another 2^28 candidates. Where the two sets meet, that is the key.
Total work: 2 times 2^28 = about 5 times 10^8 operations. On a modern GPU, this is
approximately 30 seconds to 2 minutes depending on implementation quality.

For reference, the original DFA Trojan we removed required about 50 to 100 fault pairs
and a few milliseconds of computation. Our approach requires only a single frozen-state
capture and about a minute of GPU time. Different method, same devastating result.

---

## Summary of Design Decisions

| Decision | Chosen Approach | Alternatives Rejected |
|---|---|---|
| Trigger mechanism | 6-tx alternating parity | Single magic word (too detectable) |
| Trigger complexity | 3 magic words interleaved | Single occurrence (too easy to find) |
| Deception layer | Even-tx statistical camouflage | No deception (analyst would find trigger) |
| Payload type | Deterministic FSM freeze | Analog delay glitch (unreliable across boards) |
| Hiding method | Dont-care state parasitism | New flip-flops (area increase detectable) |
| Decoy layer | Arithmetic carry glitch | No decoy (analyst might look harder) |
| Stall mechanism | Round counter loop | Clock enable gating (STA detectable) |
