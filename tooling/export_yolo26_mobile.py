#!/usr/bin/env python3
"""YOLO26-Nano mobile export toolkit for SpectruLenPor.

Produces every mobile-native deployment artifact discussed in
docs/YOLO26_MOBILE_OPTIMIZATION.md, with the exact settings this app's
inference code expects (fixed square input, end-to-end NMS head,
[1, 300, 6] output rows).

Usage:
    pip install "ultralytics>=8.4.0" onnx onnxslim
    python export_yolo26_mobile.py --weights yolo26n.pt --imgsz 640
    python export_yolo26_mobile.py --weights yolo26n.pt --imgsz 960 --only onnx,litert
    python export_yolo26_mobile.py --weights best.pt --data my_lab.yaml --int8

Outputs (next to the weights file):
    yolo26n.onnx                  FP32/FP16 ONNX, end2end=True  -> app bundles this
    yolo26n-int8.onnx             INT8-quantized ONNX (calibrated, faster CPU path)
    yolo26n_float16.tflite        LiteRT FP16
    yolo26n_int8.tflite           LiteRT INT8 (calibrated on --data)
    yolo26n.mlpackage             CoreML FP16 (iOS / Apple Neural Engine)
    yolo26n_executorch_model/     ExecuTorch .pte for XNNPACK deployment

Which artifact for which runtime?
    * Android app (current code, onnxruntime-android):
        use the end2end FP32/FP16 ONNX  -> assets/models/yolo26n.onnx.
        The app auto-benchmarks CPU vs NNAPI(+FP16) vs XNNPACK EPs at startup.
    * Android app (future TFLite path):
        use *_int8.tflite with the LiteRT interpreter (see the migration
        section of the doc) — 4x smaller, NPU/GPU delegates.
    * iOS: CoreML .mlpackage (ANE). Cross-platform C++/Java: ExecuTorch.
"""

from __future__ import annotations

import argparse
import shutil
from pathlib import Path


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--weights', default='yolo26n.pt',
                   help='YOLO26 .pt weights (yolo26n.pt or your fine-tuned best.pt)')
    p.add_argument('--imgsz', type=int, default=640,
                   help='Input resolution. 640 default; 960/1024 for small lab '
                        'objects; 320/416 for maximum speed.')
    p.add_argument('--data', default='coco8.yaml',
                   help='Dataset YAML used for INT8 calibration (any representative '
                        'set works for PTQ; use your fine-tune dataset if possible)')
    p.add_argument('--only', default='onnx,litert,coreml,executorch',
                   help='Comma list: onnx,litert,coreml,executorch')
    p.add_argument('--int8', action='store_true',
                   help='Also produce INT8 variants (onnx + litert)')
    p.add_argument('--half', action='store_true', default=True,
                   help='FP16 ONNX export (default on; pass --no-half not supported here)')
    p.add_argument('--out', default='exports', help='Output directory')
    return p.parse_args()


def main() -> None:
    args = parse_args()
    from ultralytics import YOLO  # imported lazily so --help is instant

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    targets = {t.strip().lower() for t in args.only.split(',') if t.strip()}
    weights = Path(args.weights)
    if not weights.exists():
        raise SystemExit(f'weights not found: {weights}')

    print(f'== SpectruLenPor YOLO26 mobile export ==')
    print(f'   weights={weights}  imgsz={args.imgsz}  data={args.data}')
    print(f'   targets={sorted(targets)}  int8={args.int8}\n')

    # ------------------------------------------------------------------
    # 1) ONNX — the format the current Android app consumes.
    #    nms=True keeps the end-to-end head: [1, 300, 6] rows of
    #    [x1, y1, x2, y2, score, class_id] which YoloInferenceChannel.kt parses.
    # ------------------------------------------------------------------
    if 'onnx' in targets:
        print('-- exporting ONNX (end2end NMS embedded) --')
        model = YOLO(str(weights))
        onnx_path = model.export(
            format='onnx',
            imgsz=args.imgsz,
            half=args.half,
            simplify=True,
            nms=True,          # embed NMS -> no post-processing NMS needed on-device
            dynamic=False,     # fixed [1,3,S,S] input: required by NNAPI EP
            batch=1,
            opset=18,
        )
        print(f'   -> {onnx_path}')

        if args.int8:
            print('-- exporting INT8 ONNX (PTQ, calibrated on --data) --')
            m8 = YOLO(str(weights))
            onnx_int8 = m8.export(
                format='onnx',
                imgsz=args.imgsz,
                quantize=8,
                data=args.data,
                nms=True,
                dynamic=False,
                batch=1,
            )
            print(f'   -> {onnx_int8}')

    # ------------------------------------------------------------------
    # 2) LiteRT (TFLite) — the fastest path on Android NPUs via delegates.
    #    FP16 for GPU/NN-adjacent delegates, INT8 for full NPU acceleration.
    # ------------------------------------------------------------------
    if 'litert' in targets:
        print('-- exporting LiteRT/TFLite FP16 --')
        m = YOLO(str(weights))
        tflite_fp16 = m.export(
            format='litert',
            imgsz=args.imgsz,
            quantize=16,
            nms=True,
        )
        print(f'   -> {tflite_fp16}')

        if args.int8:
            print('-- exporting LiteRT/TFLite INT8 (calibrated on --data) --')
            m8 = YOLO(str(weights))
            tflite_int8 = m8.export(
                format='litert',
                imgsz=args.imgsz,
                quantize=8,
                data=args.data,
                nms=True,
            )
            print(f'   -> {tflite_int8}')

    # ------------------------------------------------------------------
    # 3) CoreML — iOS / Apple Neural Engine (FP16 is the ANE's native math).
    # ------------------------------------------------------------------
    if 'coreml' in targets:
        print('-- exporting CoreML FP16 (.mlpackage) --')
        m = YOLO(str(weights))
        mlpackage = m.export(
            format='coreml',
            imgsz=args.imgsz,
            quantize=16,
            nms=True,
        )
        print(f'   -> {mlpackage}')

    # ------------------------------------------------------------------
    # 4) ExecuTorch — cross-platform CPU (XNNPACK backend) for future native
    #    (non-Flutter) deployments on edge hardware.
    # ------------------------------------------------------------------
    if 'executorch' in targets:
        print('-- exporting ExecuTorch (XNNPACK backend) --')
        m = YOLO(str(weights))
        et_dir = m.export(
            format='executorch',
            imgsz=args.imgsz,
        )
        print(f'   -> {et_dir}')

    # Copy every produced artifact into the output dir for tidy packaging.
    produced = []
    for pattern in ('*.onnx', '*.tflite', '*.mlpackage', '*executorch*'):
        produced.extend(Path('.').glob(pattern))
    for f in produced:
        if f.is_file() and f.parent != out_dir:
            shutil.copy2(f, out_dir / f.name)
            print(f'   copied {f} -> {out_dir}')

    print('\nDone. See docs/YOLO26_MOBILE_OPTIMIZATION.md for the integration')
    print('matrix and benchmark methodology (EP auto-selection runs on-device).')


if __name__ == '__main__':
    main()
