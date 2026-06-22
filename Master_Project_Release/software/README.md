# Software Manual

This directory contains the baremetal C source files and model headers necessary to run the classification model on the Zynq Processing System (ARM Cortex-A9).

## Files
- `nir_baremetal.c`: The main C application that configures the hardware accelerator, sends data, and reads back predictions.
- `nir_weights.h`: Generated C header containing model weights.
- `svm_q15_model.h`: Generated C header defining the SVM model structure in fixed-point (Q15) format.
- `spectra_data.h`: Test spectral data loaded for offline testing without the physical sensor.

## How to Run

1. **Launch Xilinx Vitis IDE**.
2. Create a new Application Project targeting the `.xsa` (hardware platform) exported from Vivado.
3. Select "Standalone" (baremetal) OS and "Empty Application".
4. Copy the files from this directory into the `src/` folder of your Vitis Application Project.
5. Build the project.
6. Connect the Zybo board via USB, power it on, and use the **Run As -> Launch on Hardware (Single Application Debug)** option in Vitis to execute the software on the board.
