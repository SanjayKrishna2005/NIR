#!/usr/bin/env python3
"""
gen_spectrum_hex.py
===================
Reads a SPECIM FX17e NIR spectra CSV, selects N spectra (balanced across
5 classes), writes spectrum_NNN.hex files (raw ADC 16-bit) and labels.txt
for use with tb_realdata_cosim.v and classify.py.

Expected CSV columns:
  class_id, coord_lateral, coord_driving, ch.1 ... ch.224

Output files (in --outdir):
  spectrum_000.hex ... spectrum_NNN.hex   raw 16-bit ADC, one value per line
  labels.txt                              idx  class_id  class_name

Usage:
  python3 gen_spectrum_hex.py \\
      --csv    SpectrumData_2021Y-trainSet.csv \\
      --n      50 \\
      --outdir sim/

  # Use the test set instead (e.g. for co-sim validation):
  python3 gen_spectrum_hex.py \\
      --csv    SpectrumData_2021Y-testSetLowNoise.csv \\
      --n      50 \\
      --outdir sim_low/
"""

import argparse
import os
import sys

import numpy as np
import pandas as pd

# ─────────────────────────────────────────────────────────────────────────────
CLASS_NAMES  = {1: "PE", 2: "PP", 3: "PET", 4: "PS", 5: "PVC"}
NUM_CHANNELS = 224

# ─────────────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(
        description="Generate spectrum hex files for RTL co-simulation"
    )
    p.add_argument("--csv",    required=True,
                   help="Input CSV file (trainSet, testSetLowNoise, or testSetHighNoise)")
    p.add_argument("--n",      type=int, default=50,
                   help="Total spectra to extract (default: 50)")
    p.add_argument("--outdir", default=".",
                   help="Output directory (default: current directory)")
    p.add_argument("--seed",   type=int, default=42,
                   help="Random seed for reproducible sampling (default: 42)")
    return p.parse_args()


def main():
    args = parse_args()

    if not os.path.exists(args.csv):
        print(f"ERROR: CSV not found: {args.csv}", file=sys.stderr)
        sys.exit(1)

    os.makedirs(args.outdir, exist_ok=True)

    print(f"Loading {args.csv} ...")
    df = pd.read_csv(args.csv)

    # ── Validate columns ──────────────────────────────────────────────────────
    ch_cols = [c for c in df.columns if c.startswith("ch.")]
    if len(ch_cols) != NUM_CHANNELS:
        print(f"ERROR: Expected {NUM_CHANNELS} channel columns (ch.1 … ch.224), "
              f"found {len(ch_cols)}", file=sys.stderr)
        sys.exit(1)

    if "class_id" not in df.columns:
        print("ERROR: No class_id column found", file=sys.stderr)
        sys.exit(1)

    classes = sorted(df["class_id"].unique())
    print(f"Classes found  : {classes}")
    print(f"Total rows     : {len(df)}")

    # ── Balanced stratified sampling ──────────────────────────────────────────
    per_class = args.n // len(classes)
    remainder = args.n % len(classes)

    selected_rows = []
    for i, cls in enumerate(classes):
        cls_df = df[df["class_id"] == cls]
        n_take = per_class + (1 if i < remainder else 0)
        if len(cls_df) < n_take:
            print(f"  WARNING: Class {cls} has only {len(cls_df)} rows, taking all")
            n_take = len(cls_df)
        sampled = cls_df.sample(n=n_take, random_state=args.seed)
        selected_rows.append(sampled)
        print(f"  Class {cls} ({CLASS_NAMES.get(cls,'?'):>3}) : {n_take} samples")

    # Shuffle so classes are interleaved in the sim (tests pipeline reset properly)
    selected = (pd.concat(selected_rows)
                  .sample(frac=1, random_state=args.seed)
                  .reset_index(drop=True))
    total = len(selected)
    print(f"Total selected : {total}")

    # ── Write hex files + labels.txt ──────────────────────────────────────────
    labels_path = os.path.join(args.outdir, "labels.txt")

    with open(labels_path, "w") as lf:
        lf.write("# idx  class_id  class_name\n")

        for idx, row in selected.iterrows():
            cls_id   = int(row["class_id"])
            cls_name = CLASS_NAMES.get(cls_id, "UNKNOWN")

            channels = row[ch_cols].values.astype(int)

            # Validate ADC range (SPECIM FX17e is 12-bit, 0–4095)
            if channels.min() < 0 or channels.max() > 4095:
                print(f"  WARNING: spectrum {idx:03d} out-of-range ADC values "
                      f"(min={channels.min()}, max={channels.max()})")

            # Write spectrum_NNN.hex — raw 16-bit unsigned, one per line
            hex_path = os.path.join(args.outdir, f"spectrum_{idx:03d}.hex")
            with open(hex_path, "w") as hf:
                for val in channels:
                    hf.write(f"{int(val) & 0xFFFF:04X}\n")

            lf.write(f"{idx:03d}  {cls_id}  {cls_name}\n")

    print(f"Written {total} hex files  → {args.outdir}/spectrum_NNN.hex")
    print(f"Written labels             → {labels_path}")
    print()
    print("Next steps:")
    print(f"  1. Run RTL sim:  vsim / iverilog tb_realdata_cosim.v  (reads spectrum_NNN.hex)")
    print(f"  2. Classify:     python3 classify.py \\")
    print(f"                       --features_dir {args.outdir} \\")
    print(f"                       --labels       {labels_path} \\")
    print(f"                       --weights_hex  outputs/weights.hex \\")
    print(f"                       --biases_hex   outputs/biases.hex")
    print("Done.")


if __name__ == "__main__":
    main()