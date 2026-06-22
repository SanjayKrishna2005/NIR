# Near-Infrared (NIR) Spectroscopy Accelerator - Master Release

This is the self-contained master directory for the NIR Spectroscopy Support Vector Machine (SVM) Hardware Accelerator project. Everything required to run, simulate, synthesize, and deploy the project on a Zybo Z7 (Zynq-7000 / Artix-7 fabric) board is contained within this directory.

## Directory Structure & User Manuals

This project is organized into self-contained sub-modules. **Please navigate to each specific folder and read its local `README.md` user manual for detailed instructions and commands.**

- 📂 **`dataset/`**: Contains CSV files of spectral data used for training and testing.
- 📂 **`python_models/`**: Python scripts for training the SVM model and generating C/HEX headers for hardware.
- 📂 **`rtl/`**: Core Verilog source code for the hardware accelerator and preprocessing pipeline.
- 📂 **`testbenches/`**: Verilog simulation files and memory initialization HEX files.
- 📂 **`vivado_setup/`**: TCL scripts and XDC constraints to automatically rebuild the hardware project in Xilinx Vivado.
- 📂 **`software/`**: Baremetal C code and generated headers to execute the processing system application via Xilinx Vitis.

## Quickstart Guide

If you are setting up the project from scratch, follow these phases:

1. **Model Generation:**
   Navigate to `python_models/` and run the training scripts to generate the `.pkl` and header files from the `dataset/` CSV files.
   
2. **Hardware Synthesis:**
   Navigate to `vivado_setup/` and use `build.tcl` in Vivado to generate the block design and project, bringing in the files from `rtl/`. Then generate the bitstream.

3. **Software Deployment:**
   Export the generated hardware `.xsa` from Vivado to Vitis. Use the files in `software/` to create a baremetal application, compile it, and program the connected FPGA board.

## Requirements
- Python 3.x with Scikit-learn, Numpy, Pandas (for the `python_models` directory).
- Xilinx Vivado & Vitis 2020.1 or later (for hardware generation and software deployment).
