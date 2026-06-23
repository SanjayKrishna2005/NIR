- Part : xc7a100tftg256-2
- Board: Artix-7
- Dataset Link: https://data.mendeley.com/datasets/jg2z4g6pdh/1
- ### Hardware Sensor Specifications

| Specification | Value | Description |
| :--- | :--- | :--- |
| **Sensor Model** | SPECIM FX17e | Industrial Hyperspectral Camera |
| **Wavelength Range** | 932 nm – 1720 nm | Near-Infrared (NIR) / SWIR spectrum |
| **Spectral Channels** | 224 Bands | Determines the FPGA's 224-cycle processing frame |
| **Bit Depth** | 12-bit | Raw analog-to-digital sensor resolution |
| **Hardware Speed** | 200 FPS | Camera maximum capture rate |

### Dataset Composition

The dataset contains physical samples categorized into 5 distinct chemical signatures for common recyclable plastics:

| Class ID | Plastic Type | Common Real-World Examples |
| :---: | :--- | :--- |
| **1** | **PE** (Polyethylene) | Plastic bags, toys, shampoo bottles |
| **2** | **PP** (Polypropylene) | Bottle caps, straws, yogurt containers |
| **3** | **PET** (Polyethylene Terephthalate) | Clear water bottles, soda bottles |
| **4** | **PS** (Polystyrene) | Styrofoam cups, disposable cutlery |
| **5** | **PVC** (Polyvinyl Chloride) | Plumbing pipes, medical tubing |

### Dataset Sizes (Sample Counts)

| Dataset File | Total Samples | Purpose |
| :--- | :--- | :--- |
| `trainSet.csv` | **50,000** | Used to pre-train the SVM and generate `.hex` ROM weights |
| `testSetLowNoise.csv` | **100,000** | Clean, high-quality readings for baseline evaluation |
| `testSetHighNoise.csv` | **500,000** | Difficult readings simulating a dirty, high-speed conveyor belt |
| **FPGA ROM Subset** | **200** | Extracted subset specifically for VIO standalone hardware testing |
