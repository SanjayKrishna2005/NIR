# Vivado Setup Manual

This directory provides the TCL scripts and constraints required to automatically generate the Vivado hardware project for the Zybo Z7 (Zynq-7000 / Artix-7 fabric).

## Files
- `Zybo-Z7-Master.xdc` / `Zybo-Z7-Master (1).xdc`: Hardware constraints matching the Zybo Z7 board pins.
- `build.tcl`: Main script to build the Vivado project from scratch.
- `block_design.tcl`: Generates the Zynq Processing System block design and IP integrator connections.
- `run.tcl`: Script to execute synthesis, implementation, and bitstream generation.

## How to Generate the Project

1. **Open Vivado Tcl Shell** (or the Vivado GUI Tcl Console).
2. Navigate to this directory.
3. Source the build script:
   ```tcl
   source build.tcl
   ```
   *This command will create the Vivado project, load the RTL from `../rtl/`, load the constraints, and recreate the block design.*

## How to Generate Bitstream

Once the project is built, you can run the complete implementation flow:
```tcl
source run.tcl
```
Alternatively, you can open the project in the Vivado GUI and click **Generate Bitstream**.

Once completed, export the hardware platform (`.xsa`) for the software development phase in the `software` folder.
