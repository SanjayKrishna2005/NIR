import csv
import argparse
import sys
import os

def convert_csv_to_hex(input_csv, output_prefix):
    classes = []
    features = []
    
    print(f"Reading {input_csv}...")
    try:
        with open(input_csv, 'r') as f:
            reader = csv.reader(f)
            # Skip the header row
            header = next(reader)
            
            for row in reader:
                try:
                    # Column 0 is the plastic class (1 to 5)
                    c = int(row[0])
                    # Columns 3 through 226 are the 224 data points
                    feat = [int(x) for x in row[3:227]]
                    
                    classes.append(c)
                    features.append(feat)
                except ValueError:
                    # Skip rows that don't have valid integers
                    continue
                except IndexError:
                    # Skip rows that don't have enough columns
                    continue
    except FileNotFoundError:
        print(f"Error: Could not find {input_csv}")
        sys.exit(1)

    print(f"Successfully extracted {len(classes)} valid spectra.")
    
    if len(classes) == 0:
        print("Error: No valid data found. Make sure the CSV format matches the original dataset.")
        sys.exit(1)
        
    out_feat = f"{output_prefix}_features.hex"
    out_class = f"{output_prefix}_classes.hex"
    
    print(f"Writing {out_feat} and {out_class}...")
    with open(out_feat, 'w') as f_feat, open(out_class, 'w') as f_class:
        for i in range(len(classes)):
            # Write Class (8-bit Hex)
            f_class.write(f"{classes[i]:02X}\n")
            
            # Write 224 Features (16-bit Hex)
            for j in range(224):
                # Ensure 16-bit 2's complement for negative numbers
                f_feat.write(f"{features[i][j] & 0xFFFF:04X}\n")
                
    print("\nConversion Complete! You can now load these .hex files into Vivado.")

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Convert an NIR Spectrometer CSV dataset into FPGA-compatible .hex files.")
    parser.add_argument("input_csv", help="Path to the input CSV file")
    parser.add_argument("--output", "-o", default="custom_dataset", help="Prefix for the output hex files (default: custom_dataset)")
    
    args = parser.parse_args()
    
    convert_csv_to_hex(args.input_csv, args.output)
