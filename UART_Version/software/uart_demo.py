import serial
import time
import csv

# =============================================================================
# Zybo Z7-10 Hardware UART Demo Script
# Sends 200 spectra from the dataset over UART to the FPGA, reads back the
# classification, and calculates accuracy.
# =============================================================================

COM_PORT = 'COM3'  # Windows Example (Change to /dev/ttyUSB1 on Linux/Mac)
BAUD_RATE = 115200

# Mapping class IDs to names
CLASS_MAP = {1: "PE ", 2: "PP ", 3: "PET", 4: "PS ", 5: "PVC"}

def load_test_spectra(filename, num_samples=200):
    spectra = []
    with open(filename, 'r') as f:
        reader = csv.reader(f)
        next(reader) # Skip header
        for i, row in enumerate(reader):
            if i >= num_samples:
                break
            class_id = int(row[0])
            features = [int(x) for x in row[3:227]]
            spectra.append((class_id, features))
    return spectra

def main():
    print(f"Loading 200 spectra from CSV...")
    test_data = load_test_spectra('SpectrumData_2021Y-testSetLowNoise.csv', 200)

    try:
        print(f"Connecting to FPGA on {COM_PORT} at {BAUD_RATE} baud...")
        ser = serial.Serial(COM_PORT, BAUD_RATE, timeout=2.0)
        time.sleep(1) # Wait for serial port to initialize
    except Exception as e:
        print(f"Failed to connect to {COM_PORT}: {e}")
        print("Please check your COM port and ensure the FPGA is programmed.")
        return

    correct = 0
    print("\nStarting Hardware Evaluation...\n")
    print("-" * 65)

    for i, (true_class, features) in enumerate(test_data):
        # Build the UART frame: 0xA5 (Start byte) followed by 224 * 2 bytes (little-endian)
        frame = bytearray([0xA5])
        for val in features:
            # Clamp value to unsigned 16-bit just to be safe
            v = max(0, min(0xFFFF, val))
            frame.append(v & 0xFF)         # Low byte
            frame.append((v >> 8) & 0xFF)  # High byte

        # Send frame to FPGA
        ser.write(frame)

        # Wait for the FPGA to process and send back the classification
        # FPGA sends ASCII '1'..'5' followed by '\n' (0x0A)
        response = ser.readline()

        try:
            # Decode response, ignoring the newline
            predicted_class = int(response.decode('ascii').strip())
            
            true_name = CLASS_MAP.get(true_class, "???")
            pred_name = CLASS_MAP.get(predicted_class, "???")

            if predicted_class == true_class:
                correct += 1
                status = "MATCH"
            else:
                status = "MISMATCH"

            print(f"Spectrum {i+1:>3}: True = {true_name}, FPGA = {pred_name} --> {status}")

        except Exception as e:
            print(f"Spectrum {i+1:>3}: Communication Error or Timeout! (Got: {response})")

    print("-" * 65)
    ser.close()

    accuracy = (correct / len(test_data)) * 100
    print(f"\nFPGA Hardware Evaluation Complete!")
    print(f"Total Sent: {len(test_data)}")
    print(f"Correct:    {correct}")
    print(f"Accuracy:   {accuracy:.2f}%\n")

if __name__ == '__main__':
    main()
