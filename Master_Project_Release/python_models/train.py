#!/usr/bin/env python3
"""
train_svm_rtl.py
================
RTL-faithful SVM trainer for the SPECIM FX17e NIR preprocessor pipeline.

Preprocessing mirrors the Verilog exactly:
  dark_correct      : subtract per-channel mean of dark CSV, clamp >= 0
  baseline_correct  : subtract per-spectrum mean (mean ≈ sum >> 8, N=224)
  filter_stage (SG) : convolve [-22, 88, 124, 88, -22] >> 8
  snv_norm          : (x - mean) / std  (mean ≈ sum >> 8, var ≈ sum_sq >> 8)
  quantiser         : clip(x * scale / 256) as INT8, scale default=110

Anti-overfitting / class-balance strategy:
  - Stratified K-Fold cross-validation (default K=5)
  - Grid search over multiple C values [0.001, 0.01, 0.1, 0.5, 1.0, 5.0, 10.0]
  - class_weight='balanced' on every LinearSVC candidate
  - Best C chosen by mean stratified-CV accuracy on the TRAIN split only
  - Final model retrained on full train split at best C
  - Evaluated separately on low-noise and high-noise test sets

Outputs (all in --outdir):
  weights.hex          Q15 INT16, one value per line (NUM_CLASSES × NUM_FEATURES)
  biases.hex           Q15 INT32, one value per line
  svm_q15_model.h      C header for MCU firmware
  svm_fpga_model.pkl   sklearn model (float)
  channel_min.npy      per-channel min after SNV (for optional external use)
  channel_max.npy      per-channel max after SNV
  dark_current.hex     224 × 16-bit hex, per-channel dark ROM for dark_correct.v
  cv_results.txt       full cross-validation report

Usage:
  python train_svm_rtl.py \\
      --train   path/to/train_unique.csv \\
      --dark    path/to/SpectrumData_2021Y-darkcurrent.csv \\
      --low     path/to/SpectrumData_2021Y-testSetLowNoise.csv \\
      --high    path/to/SpectrumData_2021Y-testSetHighNoise.csv \\
      --outdir  outputs/ \\
      --k       5 \\
      --scale   110
"""

import argparse
import os
import sys

import joblib
import numpy as np
import pandas as pd
from sklearn.metrics import (
    accuracy_score,
    classification_report,
    confusion_matrix,
)
from sklearn.model_selection import StratifiedKFold, cross_val_score
from sklearn.svm import LinearSVC

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────

CLASS_NAMES = {1: "PE", 2: "PP", 3: "PET", 4: "PS", 5: "PVC"}
NUM_CHANNELS = 224          # SPECIM FX17e
C_GRID = [0.001, 0.01, 0.1, 0.5, 1.0, 5.0, 10.0]

# ─────────────────────────────────────────────────────────────────────────────
# RTL-faithful preprocessing
# ─────────────────────────────────────────────────────────────────────────────

def rtl_dark_correct(X: np.ndarray, dark_ref: np.ndarray) -> np.ndarray:
    """
    dark_correct.v  — subtract dark ROM, clamp to 0.
    RTL: diff = {1b0, s_data} - {1b0, dark_rom[ch]}
         m_data = diff[16] ? 0 : diff[15:0]
    """
    out = X.astype(np.float32) - dark_ref.astype(np.float32)
    return np.clip(out, 0.0, None)


def rtl_baseline_correct(X: np.ndarray) -> np.ndarray:
    """
    baseline_correct.v — subtract per-spectrum mean.
    RTL uses sum >> 8 as the mean approximation (224 ≈ 256).
    """
    mean = (np.sum(X, axis=1, keepdims=True) / 256.0).astype(np.float32)
    return (X - mean).astype(np.float32)


def rtl_filter_sg(X: np.ndarray) -> np.ndarray:
    """
    filter_stage.v (mode=SG) — Savitzky-Golay kernel [-22, 88, 124, 88, -22] >> 8.
    RTL computes product with np.convolve 'same'; boundary samples replicate
    first/last value (the RTL initialises r0..r4 all to s_data[0] on cnt==0).
    """
    kernel = np.array([-22, 88, 124, 88, -22], dtype=np.float32) / 256.0
    out = np.zeros_like(X)
    for i in range(X.shape[0]):
        # Replicate-pad to mirror RTL boundary behaviour
        padded = np.pad(X[i], (2, 2), mode="edge")
        out[i] = np.convolve(padded, kernel, mode="valid")
    return out.astype(np.float32)


def rtl_snv_norm(X: np.ndarray) -> np.ndarray:
    """
    snv_norm.v — Standard Normal Variate.
    RTL uses sum >> 8 for mean, sum_sq >> 8 for variance (same approximation
    as baseline_correct).  std_dev = integer sqrt; recip = 32768 / std_dev.
    We mirror the same integer-sqrt approximation path:
      var  = sum((x - mean)^2) / 256
      std  = sqrt(var)  (floor integer sqrt, as RTL restoring sqrt)
      recip= 32768 / std  (integer division, 15-bit)
      out  = (x - mean) * recip / 2048  (product[26:11])
    This produces the same Q12.4 output the RTL streams to the quantiser.
    """
    N = X.shape[1]
    out = np.zeros_like(X, dtype=np.float32)

    for i in range(X.shape[0]):
        row = X[i].astype(np.float32)

        # mean: sum >> 8
        mean = float(np.sum(row)) / 256.0

        # centred
        centred = row - mean

        # variance: sum(centred^2) >> 8
        var = float(np.sum(centred ** 2)) / 256.0

        # integer floor sqrt
        std_int = int(np.floor(np.sqrt(var)))
        if std_int == 0:
            std_int = 1

        # recip: 32768 / std_int  (15-bit integer)
        recip = min(32768 // std_int, 0x7FFF)

        # output: centred * recip / 2048  (product[26:11] = >> 11, with recip 15-bit)
        # RTL wire: product = centred_p3 * {1'b0, recip}  (16b * 16b = 32b)
        #           snv_out = product[26:11]  (i.e. / 2048)
        out[i] = (centred * float(recip)) / 2048.0

    return out


def rtl_quantise(X: np.ndarray, scale: int = 110) -> np.ndarray:
    """
    quantiser.v — multiply by scale, right-shift 8, clamp to INT8.
    RTL: product = s_data * scale  (signed)
         shifted = product >> 8
         clamped = clip(shifted, -128, 127)
    """
    shifted = (X * float(scale)) / 256.0
    return np.clip(np.round(shifted), -128, 127).astype(np.int8)


def fpga_preprocess(
    X_raw: np.ndarray,
    dark_ref: np.ndarray,
    scale: int = 110,
) -> np.ndarray:
    """Full RTL-faithful pipeline. Returns INT8 (N, 224)."""
    X = rtl_dark_correct(X_raw, dark_ref)
    X = rtl_baseline_correct(X)
    X = rtl_filter_sg(X)
    X = rtl_snv_norm(X)
    X = rtl_quantise(X, scale)
    return X


# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

def load_spectrum_csv(path: str, dark_ref: np.ndarray, scale: int):
    df = pd.read_csv(path)
    y  = df["class_id"].values.astype(np.int32)
    X_raw = df.iloc[:, 3:].values.astype(np.float32)
    X_int8 = fpga_preprocess(X_raw, dark_ref, scale)
    return X_int8, y


def print_report(title: str, y_true, y_pred, fh=None):
    lines = [
        "",
        f"{'='*54}",
        f"  {title}",
        f"{'='*54}",
        f"  Accuracy : {accuracy_score(y_true, y_pred)*100:.2f}%",
        "",
        "  Confusion matrix (rows=true, cols=pred):",
    ]
    cm = confusion_matrix(y_true, y_pred)
    for row in cm:
        lines.append("    " + "  ".join(f"{v:4d}" for v in row))
    lines.append("")
    lines.append(classification_report(y_true, y_pred,
                                        target_names=[CLASS_NAMES.get(i, str(i))
                                                      for i in sorted(CLASS_NAMES)]))
    text = "\n".join(lines)
    print(text)
    if fh:
        fh.write(text + "\n")


# ─────────────────────────────────────────────────────────────────────────────
# Export helpers
# ─────────────────────────────────────────────────────────────────────────────

def export_weights_hex(W_q15: np.ndarray, path: str):
    with open(path, "w") as f:
        for row in W_q15:
            for val in row:
                f.write(f"{(int(val) & 0xFFFF):04X}\n")


def export_biases_hex(B_q15: np.ndarray, path: str):
    with open(path, "w") as f:
        for val in B_q15:
            f.write(f"{(int(val) & 0xFFFFFFFF):08X}\n")


def export_c_header(W_q15: np.ndarray, B_q15: np.ndarray,
                    num_classes: int, num_features: int, path: str):
    with open(path, "w") as f:
        f.write("#ifndef SVM_Q15_MODEL_H\n")
        f.write("#define SVM_Q15_MODEL_H\n\n")
        f.write(f"#define NUM_CLASSES  {num_classes}\n")
        f.write(f"#define NUM_FEATURES {num_features}\n\n")
        f.write(f"static const int16_t svm_weights[{num_classes}][{num_features}] = {{\n")
        for row in W_q15:
            f.write("{" + ",".join(str(int(x)) for x in row) + "},\n")
        f.write("};\n\n")
        f.write(f"static const int32_t svm_biases[{num_classes}] = {{")
        f.write(",".join(str(int(x)) for x in B_q15))
        f.write("};\n\n")
        f.write("#endif  /* SVM_Q15_MODEL_H */\n")


def export_dark_hex(dark_ref: np.ndarray, path: str):
    """
    Write dark_current.hex for dark_correct.v $readmemh.
    224 entries × 16-bit unsigned, rounded and clamped.
    """
    vals = np.round(dark_ref).astype(np.int32)
    vals = np.clip(vals, 0, 0xFFFF)
    with open(path, "w") as f:
        for v in vals:
            f.write(f"{int(v):04X}\n")


# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(
        description="RTL-matched SVM trainer for NIR spectroscopy accelerator"
    )
    p.add_argument("--train",  required=True,  help="Training CSV path")
    p.add_argument("--dark",   required=True,  help="Dark-current CSV path")
    p.add_argument("--low",    required=True,  help="Low-noise test CSV path")
    p.add_argument("--high",   required=True,  help="High-noise test CSV path")
    p.add_argument("--outdir", default=".",    help="Output directory (default: .)")
    p.add_argument("--k",      type=int, default=5,
                   help="Stratified K-Fold splits (default: 5)")
    p.add_argument("--scale",  type=int, default=110,
                   help="Quantiser scale register value (default: 110)")
    p.add_argument("--max_iter", type=int, default=20000,
                   help="LinearSVC max iterations (default: 20000)")
    return p.parse_args()


def main():
    args = parse_args()
    os.makedirs(args.outdir, exist_ok=True)

    report_path = os.path.join(args.outdir, "cv_results.txt")
    rep = open(report_path, "w")

    def log(msg=""):
        print(msg)
        rep.write(msg + "\n")

    # ── Banner ────────────────────────────────────────────────────────────────
    log("=" * 54)
    log("  RTL-FAITHFUL SVM TRAINER")
    log(f"  Quantiser scale : {args.scale}")
    log(f"  Channels        : {NUM_CHANNELS}")
    log(f"  K-Fold splits   : {args.k}")
    log(f"  C grid          : {C_GRID}")
    log(f"  class_weight    : balanced (all C candidates)")
    log("=" * 54)

    # ── Dark current ──────────────────────────────────────────────────────────
    log("\n[1/6] Loading dark current ...")
    dark_df  = pd.read_csv(args.dark)
    dark_ref = dark_df.mean(axis=0).values.astype(np.float32)
    # Trim/pad to NUM_CHANNELS in case the CSV has an index column
    if dark_ref.shape[0] != NUM_CHANNELS:
        # Try dropping first column (row index artifact)
        dark_df2 = dark_df.select_dtypes(include=[np.number])
        dark_ref = dark_df2.mean(axis=0).values.astype(np.float32)
    assert dark_ref.shape[0] == NUM_CHANNELS, (
        f"Dark ref shape {dark_ref.shape[0]} != {NUM_CHANNELS}. "
        "Check that the dark CSV has exactly 224 numeric channel columns."
    )
    log(f"  Dark ref shape  : {dark_ref.shape}  "
        f"mean={dark_ref.mean():.1f}  min={dark_ref.min():.0f}  max={dark_ref.max():.0f}")

    dark_hex_path = os.path.join(args.outdir, "dark_current.hex")
    export_dark_hex(dark_ref, dark_hex_path)
    log(f"  Written         : {dark_hex_path}")

    # ── Training data ─────────────────────────────────────────────────────────
    log("\n[2/6] Loading & preprocessing train data ...")
    X_train, y_train = load_spectrum_csv(args.train, dark_ref, args.scale)
    log(f"  Train shape     : {X_train.shape}")
    unique, counts = np.unique(y_train, return_counts=True)
    for cls, cnt in zip(unique, counts):
        log(f"    class {cls} ({CLASS_NAMES.get(cls,'?'):>3}) : {cnt:5d} samples")

    # ── Stratified K-Fold C grid search ───────────────────────────────────────
    log(f"\n[3/6] Stratified {args.k}-Fold cross-validation over C grid ...")
    log(f"  (class_weight='balanced' applied to every candidate)")
    log("")

    skf = StratifiedKFold(n_splits=args.k, shuffle=True, random_state=42)

    best_c    = None
    best_mean = -1.0
    results   = []

    header = f"  {'C':>8}  {'mean_acc':>9}  {'std_acc':>8}  {'fold_accs'}"
    log(header)
    log("  " + "-" * (len(header) - 2))

    for C in C_GRID:
        svm_cv = LinearSVC(
            C=C,
            class_weight="balanced",
            dual=False,
            max_iter=args.max_iter,
            random_state=42,
        )
        scores = cross_val_score(
            svm_cv, X_train, y_train,
            cv=skf, scoring="accuracy", n_jobs=-1,
        )
        mean_acc = scores.mean()
        std_acc  = scores.std()
        fold_str = "  ".join(f"{s*100:.2f}%" for s in scores)
        log(f"  {C:>8.4f}  {mean_acc*100:>8.2f}%  {std_acc*100:>7.2f}%  [{fold_str}]")
        results.append((C, mean_acc, std_acc, scores))

        if mean_acc > best_mean:
            best_mean = mean_acc
            best_c    = C

    log("")
    log(f"  >>> Best C = {best_c}  (mean CV accuracy = {best_mean*100:.2f}%)")

    # ── Train final model on full train set ───────────────────────────────────
    log(f"\n[4/6] Training final LinearSVC  C={best_c}, class_weight='balanced' ...")
    svm_final = LinearSVC(
        C=best_c,
        class_weight="balanced",
        dual=False,
        max_iter=args.max_iter,
        random_state=42,
    )
    svm_final.fit(X_train, y_train)
    log("  Training complete.")

    # Train-set self-evaluation (sanity check — not a fair accuracy measure)
    pred_train = svm_final.predict(X_train)
    log(f"  Train-set accuracy (self-eval): {accuracy_score(y_train, pred_train)*100:.2f}%")

    # ── Test: low noise ───────────────────────────────────────────────────────
    log("\n[5/6] Test sets ...")
    X_low, y_low = load_spectrum_csv(args.low,  dark_ref, args.scale)
    X_high, y_high = load_spectrum_csv(args.high, dark_ref, args.scale)

    pred_low  = svm_final.predict(X_low)
    pred_high = svm_final.predict(X_high)

    print_report("LOW-NOISE TEST SET",  y_low,  pred_low,  rep)
    print_report("HIGH-NOISE TEST SET", y_high, pred_high, rep)

    # ── Export ────────────────────────────────────────────────────────────────
    log("\n[6/6] Exporting weights ...")

    W = svm_final.coef_          # (num_classes, 224)
    B = svm_final.intercept_     # (num_classes,)
    num_classes  = W.shape[0]
    num_features = W.shape[1]

    log(f"  Weight matrix   : {W.shape}")
    log(f"  Bias vector     : {B.shape}")

    # Q15 conversion  (same as doc-1 convention: * 32767)
    W_q15 = np.round(W * 32767).astype(np.int16)
    B_q15 = np.round(B * 32767).astype(np.int32)

    w_path = os.path.join(args.outdir, "weights.hex")
    b_path = os.path.join(args.outdir, "biases.hex")
    h_path = os.path.join(args.outdir, "svm_q15_model.h")
    p_path = os.path.join(args.outdir, "svm_fpga_model.pkl")

    export_weights_hex(W_q15, w_path)
    export_biases_hex(B_q15, b_path)
    export_c_header(W_q15, B_q15, num_classes, num_features, h_path)
    joblib.dump(svm_final, p_path)

    # Optional: per-channel min/max after SNV (kept for compatibility with
    # classify.py quantisation path — not used by LinearSVC inference)
    X_snv_float = rtl_snv_norm(
        rtl_filter_sg(
            rtl_baseline_correct(
                rtl_dark_correct(
                    pd.read_csv(args.train).iloc[:, 3:].values.astype(np.float32),
                    dark_ref,
                )
            )
        )
    )
    ch_min = X_snv_float.min(axis=0)
    ch_max = X_snv_float.max(axis=0)
    np.save(os.path.join(args.outdir, "channel_min.npy"), ch_min)
    np.save(os.path.join(args.outdir, "channel_max.npy"), ch_max)

    log("")
    log("  Files written:")
    for f in [w_path, b_path, h_path, p_path, dark_hex_path,
              os.path.join(args.outdir, "channel_min.npy"),
              os.path.join(args.outdir, "channel_max.npy"),
              report_path]:
        log(f"    {f}")

    log("")
    log("Done.")
    rep.close()


if __name__ == "__main__":
    main()