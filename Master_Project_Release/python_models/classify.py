#!/usr/bin/env python3
"""
classify.py  — LinearSVC Q15 inference on RTL INT8 features
=============================================================
Reads features_NNN.hex files produced by the RTL preprocessor pipeline
(dark_correct → baseline_correct → filter_stage(SG) → snv_norm → quantiser),
loads Q15 weights from svm_q15_model.h (or weights.hex + biases.hex), and
classifies each spectrum directly — no PCA, no MLP.

Inference:
  RTL INT8 (224,) → dot(W_q15, x) + b_q15 → argmax → class_id

Score computation (Q15 fixed-point safe):
  score[c] = sum(W_q15[c,:] * int8[:]) + b_q15[c]
  W_q15 : int16, range ±32767  (= float_weight * 32767)
  b_q15 : int32, range ±32767  (= float_bias   * 32767)
  x     : int8,  range ±127

  All arithmetic done in int32/int64 to avoid overflow.
  Decision: argmax(score) → 1-indexed class_id

Usage:
  python3 classify.py \\
      --features_dir sim/ \\
      --labels       sim/labels.txt \\
      --weights_hex  outputs/weights.hex \\
      --biases_hex   outputs/biases.hex \\
      [--n 50]

  Alternatively, point at the .pkl model directly:
      --pkl          outputs/svm_fpga_model.pkl
"""

import argparse
import os
import sys
import numpy as np

# ─────────────────────────────────────────────────────────────────────────────
CLASS_NAMES  = {1: "PE", 2: "PP", 3: "PET", 4: "PS", 5: "PVC"}
NUM_CLASSES  = 5
NUM_FEATURES = 224

# ─────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ─────────────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(
        description="LinearSVC Q15 inference on RTL INT8 feature hex files"
    )
    p.add_argument("--features_dir", default=".",
                   help="Directory containing features_NNN.hex files")
    p.add_argument("--labels",       default="labels.txt",
                   help="labels.txt produced by gen_spectrum_hex.py")
    p.add_argument("--weights_hex",  default="weights.hex",
                   help="Q15 INT16 weight hex (one value per line, classes × features)")
    p.add_argument("--biases_hex",   default="biases.hex",
                   help="Q15 INT32 bias hex (one value per line, one per class)")
    p.add_argument("--pkl",          default=None,
                   help="Optional: use sklearn .pkl directly instead of hex files")
    p.add_argument("--n",            type=int, default=None,
                   help="Limit to first N samples in labels.txt")
    return p.parse_args()

# ─────────────────────────────────────────────────────────────────────────────
# Loaders
# ─────────────────────────────────────────────────────────────────────────────

def load_labels(path: str) -> dict:
    labels = {}
    if not os.path.exists(path):
        print(f"ERROR: labels not found: {path}", file=sys.stderr)
        sys.exit(1)
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 3:
                labels[int(parts[0])] = (int(parts[1]), parts[2])
    return labels


def load_features_hex(path: str) -> np.ndarray:
    """Read one features_NNN.hex → signed int8 array (224,)."""
    vals = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            b = int(line, 16) & 0xFF
            vals.append(b - 256 if b > 127 else b)
    if len(vals) != NUM_FEATURES:
        raise ValueError(f"Expected {NUM_FEATURES} values, got {len(vals)}")
    return np.array(vals, dtype=np.int8)


def load_weights_hex(w_path: str, b_path: str):
    """
    Load Q15 weights and biases from hex files.
    weights.hex : NUM_CLASSES × NUM_FEATURES int16 values, one per line, row-major
    biases.hex  : NUM_CLASSES int32 values, one per line
    Returns W (NUM_CLASSES, NUM_FEATURES) int16,  b (NUM_CLASSES,) int32
    """
    if not os.path.exists(w_path):
        print(f"ERROR: weights not found: {w_path}", file=sys.stderr); sys.exit(1)
    if not os.path.exists(b_path):
        print(f"ERROR: biases not found: {b_path}", file=sys.stderr); sys.exit(1)

    # Weights: 4-hex-digit signed int16
    raw_w = []
    with open(w_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            v = int(line, 16) & 0xFFFF
            raw_w.append(v - 65536 if v > 32767 else v)

    expected = NUM_CLASSES * NUM_FEATURES
    if len(raw_w) != expected:
        print(f"ERROR: weights.hex has {len(raw_w)} values, expected {expected}",
              file=sys.stderr)
        sys.exit(1)

    W = np.array(raw_w, dtype=np.int16).reshape(NUM_CLASSES, NUM_FEATURES)

    # Biases: 8-hex-digit signed int32
    raw_b = []
    with open(b_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            v = int(line, 16) & 0xFFFFFFFF
            raw_b.append(v - (1 << 32) if v > 0x7FFFFFFF else v)

    if len(raw_b) != NUM_CLASSES:
        print(f"ERROR: biases.hex has {len(raw_b)} values, expected {NUM_CLASSES}",
              file=sys.stderr)
        sys.exit(1)

    b = np.array(raw_b, dtype=np.int32)
    return W, b


# ─────────────────────────────────────────────────────────────────────────────
# Inference
# ─────────────────────────────────────────────────────────────────────────────

def infer_q15(x_int8: np.ndarray, W: np.ndarray, b: np.ndarray) -> int:
    """
    Q15 LinearSVC inference.
    x_int8 : (224,) int8
    W      : (5, 224) int16  — W_q15 = round(float_weight * 32767)
    b      : (5,)     int32  — b_q15 = round(float_bias   * 32767)

    score[c] = dot(W[c], x) + b[c]   computed in int32
    Returns 1-indexed class_id (1..5).
    """
    x32 = x_int8.astype(np.int32)          # (224,) int32
    W32 = W.astype(np.int32)               # (5,224) int32
    scores = W32 @ x32 + b.astype(np.int32)  # (5,) int32  — no overflow risk
    return int(np.argmax(scores)) + 1


def infer_pkl(x_int8: np.ndarray, svm) -> int:
    """sklearn LinearSVC float inference (reference path)."""
    return int(svm.predict(x_int8.reshape(1, -1).astype(np.float32))[0])


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def main():
    args   = parse_args()
    labels = load_labels(args.labels)

    # Choose inference backend
    use_pkl = args.pkl is not None
    if use_pkl:
        try:
            import joblib
        except ImportError:
            print("ERROR: joblib not installed — needed for --pkl mode", file=sys.stderr)
            sys.exit(1)
        if not os.path.exists(args.pkl):
            print(f"ERROR: pkl not found: {args.pkl}", file=sys.stderr); sys.exit(1)
        svm = joblib.load(args.pkl)
        W = b = None
        print(f"Backend        : sklearn pkl  ({args.pkl})")
    else:
        W, b = load_weights_hex(args.weights_hex, args.biases_hex)
        svm  = None
        print(f"Backend        : Q15 hex  ({args.weights_hex}, {args.biases_hex})")
        print(f"Weight shape   : {W.shape}  dtype={W.dtype}")
        print(f"Bias shape     : {b.shape}  dtype={b.dtype}")
        print(f"Weight range   : [{W.min()}, {W.max()}]")

    n_samples = args.n if args.n is not None else len(labels)

    print(f"Labels loaded  : {len(labels)} entries")
    print(f"Features dir   : {args.features_dir}")
    print(f"Samples        : {n_samples}")
    print()
    print(f"{'IDX':>4}  {'TRUE_ID':>7}  {'TRUE_NAME':>9}  "
          f"{'PRED_ID':>7}  {'PRED_NAME':>9}  {'OK':>4}")
    print("-" * 55)

    correct = total = missing = 0

    for idx in sorted(labels.keys()):
        if total >= n_samples:
            break

        path = os.path.join(args.features_dir, f"features_{idx:03d}.hex")
        if not os.path.exists(path):
            print(f"{idx:>4}  -- missing")
            missing += 1
            continue

        try:
            x = load_features_hex(path)
        except Exception as e:
            print(f"{idx:>4}  ERROR: {e}")
            missing += 1
            continue

        true_cls_id, true_cls_name = labels[idx]

        if use_pkl:
            pred_cls_id = infer_pkl(x, svm)
        else:
            pred_cls_id = infer_q15(x, W, b)

        pred_cls_name = CLASS_NAMES.get(pred_cls_id, "?")
        ok = (pred_cls_id == true_cls_id)
        if ok:
            correct += 1
        total += 1

        print(f"{idx:>4}  {true_cls_id:>7}  {true_cls_name:>9}  "
              f"{pred_cls_id:>7}  {pred_cls_name:>9}  {'✓' if ok else '✗':>4}")

    print("-" * 55)
    if missing:
        print(f"WARNING: {missing} files missing or unreadable")
    if total == 0:
        print("ERROR: no samples processed")
        sys.exit(1)
    print(f"Correct  : {correct}/{total}")
    print(f"Accuracy : {100.0 * correct / total:.2f}%")


if __name__ == "__main__":
    main()