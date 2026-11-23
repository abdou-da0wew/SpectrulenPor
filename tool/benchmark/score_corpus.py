#!/usr/bin/env python3
"""Score SpectruLenPor STT and object-detection benchmark manifests."""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any


def normalize_text(value: str) -> str:
    value = unicodedata.normalize("NFKC", value).lower()
    value = re.sub(r"[\u064B-\u065F\u0670\u0640]", "", value)
    value = re.sub(r"[^\w\s]", " ", value, flags=re.UNICODE)
    return " ".join(value.split())


def edit_distance(left: list[Any], right: list[Any]) -> int:
    if not left:
        return len(right)
    if not right:
        return len(left)
    previous = list(range(len(right) + 1))
    for i, item in enumerate(left, 1):
        current = [i] + [0] * len(right)
        for j, other in enumerate(right, 1):
            current[j] = min(
                previous[j] + 1,
                current[j - 1] + 1,
                previous[j - 1] + (0 if item == other else 1),
            )
        previous = current
    return previous[-1]


def score_stt(data: dict[str, Any]) -> dict[str, Any]:
    samples = data.get("samples")
    if not isinstance(samples, list) or not samples:
        raise ValueError("STT manifest must contain a non-empty samples array.")

    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    total_word_errors = total_words = 0
    total_char_errors = total_chars = exact = 0
    results = []

    for sample in samples:
        if not isinstance(sample, dict):
            raise ValueError("Every STT sample must be an object.")
        language = str(sample.get("language", "und"))
        reference = normalize_text(str(sample.get("reference", "")))
        hypothesis = normalize_text(str(sample.get("hypothesis", "")))
        if not reference:
            raise ValueError(f"STT sample {sample.get('id', '?')} has an empty reference.")
        ref_words = reference.split()
        hyp_words = hypothesis.split()
        word_errors = edit_distance(ref_words, hyp_words)
        char_errors = edit_distance(list(reference), list(hypothesis))
        word_count = len(ref_words)
        char_count = len(reference)
        is_exact = reference == hypothesis

        total_word_errors += word_errors
        total_words += word_count
        total_char_errors += char_errors
        total_chars += char_count
        exact += int(is_exact)
        groups[language].append({
            "wordErrors": word_errors,
            "words": word_count,
            "charErrors": char_errors,
            "characters": char_count,
            "exact": is_exact,
        })
        results.append({
            "id": sample.get("id"),
            "language": language,
            "wordErrorRate": word_errors / max(1, word_count),
            "characterErrorRate": char_errors / max(1, char_count),
            "exactMatch": is_exact,
        })

    per_language = {}
    for language, rows in sorted(groups.items()):
        word_errors = sum(row["wordErrors"] for row in rows)
        words = sum(row["words"] for row in rows)
        char_errors = sum(row["charErrors"] for row in rows)
        characters = sum(row["characters"] for row in rows)
        per_language[language] = {
            "sampleCount": len(rows),
            "wordErrorRate": word_errors / max(1, words),
            "characterErrorRate": char_errors / max(1, characters),
            "exactMatchRate": sum(row["exact"] for row in rows) / len(rows),
        }

    return {
        "task": "stt",
        "corpus": data.get("corpus"),
        "sampleCount": len(samples),
        "wordErrorRate": total_word_errors / max(1, total_words),
        "characterErrorRate": total_char_errors / max(1, total_chars),
        "exactMatchRate": exact / len(samples),
        "perLanguage": per_language,
        "samples": results,
    }


def box_iou(left: list[float], right: list[float]) -> float:
    lx1, ly1, lx2, ly2 = left
    rx1, ry1, rx2, ry2 = right
    ix1, iy1 = max(lx1, rx1), max(ly1, ry1)
    ix2, iy2 = min(lx2, rx2), min(ly2, ry2)
    iw, ih = max(0.0, ix2 - ix1), max(0.0, iy2 - iy1)
    intersection = iw * ih
    la = max(0.0, lx2 - lx1) * max(0.0, ly2 - ly1)
    ra = max(0.0, rx2 - rx1) * max(0.0, ry2 - ry1)
    union = la + ra - intersection
    return intersection / union if union > 0 else 0.0


def average_precision_101(precisions: list[float], recalls: list[float]) -> float:
    area = 0.0
    for step in range(101):
        recall_threshold = step / 100.0
        eligible = [
            precision
            for precision, recall in zip(precisions, recalls)
            if recall >= recall_threshold
        ]
        area += max(eligible, default=0.0)
    return area / 101.0


def score_vision(data: dict[str, Any], iou_threshold: float = 0.5) -> dict[str, Any]:
    images = data.get("images")
    if not isinstance(images, list) or not images:
        raise ValueError("Vision manifest must contain a non-empty images array.")

    ground_truth: dict[tuple[str, int], list[list[float]]] = defaultdict(list)
    predictions: dict[int, list[tuple[float, str, list[float]]]] = defaultdict(list)
    class_labels: dict[int, str] = {}
    for image in images:
        image_id = str(image.get("id"))
        annotations = image.get("annotations", [])
        detections = image.get("predictions", [])
        for annotation in annotations:
            class_id = int(annotation["classId"])
            box = [float(v) for v in annotation["box"]]
            if len(box) != 4:
                raise ValueError(f"Invalid annotation box in image {image_id}")
            ground_truth[(image_id, class_id)].append(box)
            class_labels[class_id] = str(annotation.get("label", class_id))
        for detection in detections:
            class_id = int(detection["classId"])
            box = [float(v) for v in detection["box"]]
            if len(box) != 4:
                raise ValueError(f"Invalid prediction box in image {image_id}")
            confidence = float(detection["confidence"])
            predictions[class_id].append((confidence, image_id, box))
            class_labels[class_id] = str(detection.get("label", class_id))

    ground_truth_classes = {class_id for _, class_id in ground_truth}
    classes = sorted(ground_truth_classes | set(predictions))
    if not ground_truth_classes:
        raise ValueError("Vision manifest contains no ground-truth annotations.")

    per_class = {}
    total_tp = total_fp = total_gt = 0
    aps = []
    for class_id in classes:
        gt_images = {
            image_id: list(boxes)
            for (image_id, found_class), boxes in ground_truth.items()
            if found_class == class_id
        }
        matched = {
            image_id: [False] * len(boxes)
            for image_id, boxes in gt_images.items()
        }
        total_gt_class = sum(len(boxes) for boxes in gt_images.values())
        ordered = sorted(predictions.get(class_id, []), key=lambda row: row[0], reverse=True)
        true_positive = []
        false_positive = []

        for confidence, image_id, predicted_box in ordered:
            candidates = gt_images.get(image_id, [])
            best_iou, best_index = 0.0, -1
            for index, actual_box in enumerate(candidates):
                score = box_iou(predicted_box, actual_box)
                if score > best_iou:
                    best_iou, best_index = score, index
            if best_iou >= iou_threshold and best_index >= 0 and not matched[image_id][best_index]:
                matched[image_id][best_index] = True
                true_positive.append(1)
                false_positive.append(0)
            else:
                true_positive.append(0)
                false_positive.append(1)

        cumulative_tp = cumulative_fp = 0
        precision_curve = []
        recall_curve = []
        for tp, fp in zip(true_positive, false_positive):
            cumulative_tp += tp
            cumulative_fp += fp
            precision_curve.append(cumulative_tp / max(1, cumulative_tp + cumulative_fp))
            recall_curve.append(cumulative_tp / max(1, total_gt_class))

        ap = average_precision_101(precision_curve, recall_curve)
        tp_count = sum(true_positive)
        fp_count = sum(false_positive)
        fn_count = total_gt_class - tp_count
        precision = tp_count / max(1, tp_count + fp_count)
        recall = tp_count / max(1, tp_count + fn_count)
        per_class[str(class_id)] = {
            "label": class_labels.get(class_id, str(class_id)),
            "groundTruthCount": total_gt_class,
            "predictionCount": len(ordered),
            "truePositive": tp_count,
            "falsePositive": fp_count,
            "falseNegative": fn_count,
            "precision": precision,
            "recall": recall,
            "ap50": ap,
        }
        total_tp += tp_count
        total_fp += fp_count
        total_gt += total_gt_class
        if total_gt_class > 0:
            aps.append(ap)

    return {
        "task": "vision",
        "corpus": data.get("corpus"),
        "imageCount": len(images),
        "iouThreshold": iou_threshold,
        "precision": total_tp / max(1, total_tp + total_fp),
        "recall": total_tp / max(1, total_gt),
        "map50": sum(aps) / max(1, len(aps)),
        "perClass": per_class,
        "note": "AP uses 101-point interpolated precision at IoU 0.50.",
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("task", choices=("stt", "vision"))
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--iou", type=float, default=0.5)
    args = parser.parse_args()

    try:
        data = json.loads(args.manifest.read_text(encoding="utf-8"))
        report = score_stt(data) if args.task == "stt" else score_vision(data, args.iou)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        return 0
    except (OSError, json.JSONDecodeError, KeyError, TypeError, ValueError) as error:
        print(f"benchmark scoring failed: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
