#!/usr/bin/env python3
"""
SpectruLenPor — specialized model conversion for ONNX Runtime Mobile.

Produces the two files the app expects in `assets/models/`:
    model.onnx    — dynamic-range quantized (int8 weights, float I/O)
    labels.txt    — class names in index order

Usage:
    pip install torch torchvision onnx onnxruntime
    python tooling/convert_mobilenet_onnx.py [--output_dir assets/models]

Default: MobileNetV2 ImageNet (everyday objects + many lab items).
For a SCIENTIFIC classifier (lab equipment / chemical bottles):
    1. Collect your dataset (phone photos through the glasses!), folders
       named per class.
    2. Fine-tune torchvision.mobilenet_v2 (replace head) — 10 min on CPU
       for a few hundred photos per class.
    3. Export + quantize with the same code path (swap the weights loading).

Why dynamic-range quantization:
    * 4x smaller, ~2-3x faster on phone CPUs (XNNPACK int8 kernels)
    * float I/O preserved -> the Dart preprocessing stays simple (0-1 NCHW)
"""

import argparse
import os

import torch
import torch.nn as nn
import torchvision
from torchvision import models


def export_fp32(model: nn.Module, path: str) -> None:
    model.eval()
    dummy = torch.randn(1, 3, 224, 224)

    torch.onnx.export(
        model,
        dummy,
        path,
        export_params=True,
        opset_version=17,          # ORT Mobile friendly
        do_constant_folding=True,  # graph opt at export time
        input_names=["input"],
        output_names=["output"],
        dynamic_axes={"input": {0: "batch"}, "output": {0: "batch"}},
    )
    print(f"[export] fp32  -> {path} "
          f"({os.path.getsize(path) / 1e6:.1f} MB)")


def quantize_dynamic(path_in: str, path_out: str) -> None:
    import onnx
    from onnxruntime.quantization import quantize_dynamic, QuantType

    onnx.shape_inference.infer_shapes_path(path_in, path_in + ".shapes")
    quantize_dynamic(
        model_input=path_in,
        model_output=path_out,
        weight_type=QuantType.QInt8,
        per_channel=True,          # better accuracy than per-tensor
        reduce_range=False,
        optimize_model=True,
    )
    os.remove(path_in + ".shapes")
    print(f"[quant ] int8  -> {path_out} "
          f"({os.path.getsize(path_out) / 1e6:.1f} MB)")


def write_labels(labels, path: str) -> None:
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(labels))
    print(f"[labels] {len(labels)} classes -> {path}")


def sanity_check(model_path: str) -> None:
    import numpy as np
    import onnxruntime as ort

    sess = ort.InferenceSession(
        model_path,
        providers=["CPUExecutionProvider"],
    )
    x = np.random.rand(1, 3, 224, 224).astype(np.float32)
    out = sess.run(None, {sess.get_inputs()[0].name: x})[0]
    top1 = int(out[0].argmax())
    print(f"[check ] ORT Mobile OK — output shape {out.shape}, "
          f"random top-1 class index {top1}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--output_dir", default="assets/models")
    ap.add_argument(
        "--skip_download", action="store_true",
        help="export from already-downloaded weights (offline reruns)")
    args = ap.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)
    fp32_path = os.path.join(args.output_dir, "model_fp32.tmp.onnx")
    final_path = os.path.join(args.output_dir, "model.onnx")
    labels_path = os.path.join(args.output_dir, "labels.txt")

    # 1) Load pretrained MobileNetV2 (ImageNet).
    print("[load  ] torchvision mobilenet_v2 (ImageNet weights)…")
    weights = models.MobileNet_V2_Weights.IMAGENET1K_V1
    model = models.mobilenet_v2(weights=weights if not args.skip_download else None)

    # 2) Export fp32 ONNX.
    export_fp32(model, fp32_path)

    # 3) Dynamic-range quantization (int8 weights).
    quantize_dynamic(fp32_path, final_path)
    os.remove(fp32_path)

    # 4) Labels (torchvision category list matches index order).
    write_labels(weights.meta["categories"], labels_path)

    # 5) Sanity check with onnxruntime.
    sanity_check(final_path)

    print("\nDone. Copy the files into the Flutter app:")
    print(f"  {final_path}  -> smart_glass_app/assets/models/model.onnx")
    print(f"  {labels_path} -> smart_glass_app/assets/models/labels.txt")
    print("Then rebuild: flutter pub get && flutter build apk")


if __name__ == "__main__":
    main()
