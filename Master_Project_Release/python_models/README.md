# Python Models Manual

This directory contains the Python scripts to train the Support Vector Machine (SVM) model, perform inference, and export the trained weights to headers/hex files for hardware deployment.

## Scripts & Usage

1. **`train.py`**
   Trains the base SVM classification model.
   ```bash
   python train.py
   ```

2. **`train_svm_rtl.py`**
   Trains the model and structures it specifically to map weights and biases for the RTL implementation.
   ```bash
   python train_svm_rtl.py
   ```

3. **`classify.py`**
   Runs inference using the saved model (`svm_fpga_model.pkl`) against the test datasets.
   ```bash
   python classify.py
   ```

4. **`gen_c_weights.py`**
   Generates C header files (`nir_weights.h`, `svm_q15_model.h`) containing quantized model weights for the baremetal software application.
   ```bash
   python gen_c_weights.py
   ```

5. **`gen_spectra_header.py`**
   Extracts sample spectral data and formats it as a C array header (`spectra_data.h`) for testing the baremetal software without physical sensors.
   ```bash
   python gen_spectra_header.py
   ```

6. **`gen_spectrum_hex.py`**
   Generates memory `.hex` files containing spectra data, model weights, and biases to load into BRAM for hardware testbench simulations.
   ```bash
   python gen_spectrum_hex.py
   ```

## Generated Artifacts
- `svm_fpga_model.pkl`: The serialized SVM model.
- `channel_max.npy` & `channel_min.npy`: Normalization constants.
