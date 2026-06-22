# RTL Manual

This directory contains the core Verilog source files for the Near-Infrared (NIR) spectrum processing and classification hardware accelerator.

## Modules Overview
- `zybo_top.v`: Top-level module integrating the accelerator within the Zynq Processing System.
- `accel_top.v`: The main hardware accelerator wrapper.
- `preprocess_top.v`: Top-level pre-processing pipeline for the raw spectrum.
- `dark_correct.v`: Subtracts dark current from raw signals.
- `baseline_correct.v`: Applies baseline correction.
- `filter_stage.v`: Digital filtering for smoothing noise.
- `snv_norm.v`: Standard Normal Variate (SNV) normalization.
- `quantiser.v`: Handles precision scaling and quantization.
- `config_regs.v`: AXI4-Lite configuration registers to interface with the processor.
- `spi_tx.v`: SPI transmission interface (if interfacing with an external sensor/ADC).

## Synthesis & Implementation
These files are automatically loaded by the Vivado scripts in the `vivado_setup` directory.
You do not need to manually run any tools in this folder. Proceed to `vivado_setup` for bitstream generation.
