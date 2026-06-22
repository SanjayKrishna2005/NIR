# Testbenches Manual

This directory contains the Verilog simulation testbenches and memory initialization files to verify the RTL functionality before synthesis.

## Files
- `tb_zybo_top.v`: Testbench for the complete Zybo top-level design.
- `tb_zybo_cosim.v`: Testbench for co-simulation with the processing system.
- `tb_realdata_cosim.v`: Testbench injecting real datasets into the accelerator pipeline.
- `weights.hex`, `biases.hex`, `dark_current.hex`: Pre-generated HEX files containing weights and configuration data for the simulation models.

## How to Run Simulations
The easiest way to run the simulations is using Xilinx Vivado.

1. Open the Vivado project (created via the `vivado_setup` folder).
2. Add these files to the Simulation Sources of your project.
3. Set the desired testbench (e.g., `tb_zybo_top`) as the active top module for simulation.
4. Run the Behavioral Simulation:
   - In Vivado GUI: Click **Run Simulation** -> **Run Behavioral Simulation**.
   - Note: The `.hex` files must be in the simulation working directory or referenced with absolute paths in the Verilog `$readmemh` system tasks.
