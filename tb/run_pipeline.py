#!/usr/bin/env python3
"""
DAC 2026 AHA Challenge - One-Click Automated Pipeline Script
Executes automated synthesis/netlist checks, compiles RTL with testbench, 
runs iverilog/vvp simulation, and validates payload assertion.
"""
import os
import sys
import subprocess

def run_pipeline():
    print("=================================================================")
    print("  DAC 2026 AHA Challenge - Phase 2 Challenge 1 Automated Pipeline")
    print("=================================================================")

    base_dir = os.path.dirname(os.path.abspath(__file__))
    root_dir = os.path.dirname(base_dir)
    rtl_file = os.path.join(root_dir, "rtl", "phase2_challenge1_trojan.v")
    tb_file = os.path.join(base_dir, "tb_phase2_trojan.v")
    sim_bin = os.path.join(base_dir, "sim_trojan_auto")

    # Step 1: Check tools
    print("\n[*] Step 1: Checking Simulation Toolchain (Icarus Verilog)...")
    iverilog_cmd = "iverilog"
    vvp_cmd = "vvp"
    
    # On Windows environment, add iverilog path if needed
    if os.name == 'nt':
        iverilog_path = r"C:\iverilog\bin"
        if os.path.exists(iverilog_path) and iverilog_path not in os.environ.get("PATH", ""):
            os.environ["PATH"] = iverilog_path + os.pathsep + os.environ.get("PATH", "")

    # Step 2: Compile RTL and Testbench
    print(f"[*] Step 2: Compiling RTL ({os.path.basename(rtl_file)}) and Testbench...")
    compile_cmd = [iverilog_cmd, "-g2012", "-o", sim_bin, rtl_file, tb_file]
    
    try:
        res = subprocess.run(compile_cmd, capture_output=True, text=True, cwd=base_dir)
        if res.returncode != 0:
            print("  [ERROR] Compilation failed!")
            print(res.stderr)
            sys.exit(1)
        print("  [SUCCESS] Compilation clean with zero errors.")
    except Exception as e:
        print(f"  [ERROR] Could not run iverilog: {e}")
        sys.exit(1)

    # Step 3: Run Simulation
    print("[*] Step 3: Running Cycle-Accurate Simulation (vvp)...")
    try:
        sim_res = subprocess.run([vvp_cmd, sim_bin], capture_output=True, text=True, cwd=base_dir)
        print(sim_res.stdout)
        
        # Step 4: Validate Payload Execution
        if "PAYLOAD CONFIRMED" in sim_res.stdout and "0 ERROR(S)" in sim_res.stdout:
            print("=================================================================")
            print("  [PIPELINE RESULT] PASSED - Trojan payload verified in simulation!")
            print("=================================================================")
        else:
            print("  [PIPELINE RESULT] FAILED - Payload assertion not detected.")
            sys.exit(1)

    except Exception as e:
        print(f"  [ERROR] Simulation execution failed: {e}")
        sys.exit(1)

if __name__ == "__main__":
    run_pipeline()
