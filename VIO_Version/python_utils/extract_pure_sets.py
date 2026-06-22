import csv

def extract_balanced_samples(filename, num_per_class):
    counts = {1: 0, 2: 0, 3: 0, 4: 0, 5: 0}
    extracted_classes = []
    extracted_features = []
    
    with open(filename, 'r') as f:
        reader = csv.reader(f)
        header = next(reader)
        for row in reader:
            try:
                c = int(row[0])
            except ValueError:
                continue
            
            if c in counts and counts[c] < num_per_class:
                counts[c] += 1
                extracted_classes.append(c)
                extracted_features.append([int(x) for x in row[3:227]])
                
            if all(v >= num_per_class for v in counts.values()):
                break
                
    return extracted_classes, extracted_features

def write_hex(prefix, classes, features):
    with open(f'{prefix}_features.hex', 'w') as f_feat, open(f'{prefix}_classes.hex', 'w') as f_class:
        for i in range(len(classes)):
            f_class.write(f"{classes[i]:02X}\n")
            for j in range(224):
                f_feat.write(f"{features[i][j] & 0xFFFF:04X}\n")

# 200 Low Noise (40 per class * 5)
print("Extracting 200 Pure Low Noise...")
low_c, low_f = extract_balanced_samples('SpectrumData_2021Y-testSetLowNoise.csv', 40)
write_hex('test_200_low', low_c, low_f)

# 200 High Noise (40 per class * 5)
print("Extracting 200 Pure High Noise...")
high_c, high_f = extract_balanced_samples('SpectrumData_2021Y-testSetHighNoise.csv', 40)
write_hex('test_200_high', high_c, high_f)

print("Done! Generated test_200_low_*.hex and test_200_high_*.hex")
