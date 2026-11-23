import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from score_corpus import score_stt, score_vision


class CorpusScoringTests(unittest.TestCase):
    def test_stt_reports_zero_errors_for_exact_bilingual_transcripts(self):
        report = score_stt({
            "corpus": "test",
            "samples": [
                {"id": "en-1", "language": "en-US", "reference": "Turn on the UV light.", "hypothesis": "Turn on the UV light."},
                {"id": "ar-1", "language": "ar-EG", "reference": "مرحبا بالعالم", "hypothesis": "مَرْحَبًا بِالْعَالَم"},
            ],
        })
        self.assertEqual(report["wordErrorRate"], 0.0)
        self.assertEqual(report["characterErrorRate"], 0.0)
        self.assertEqual(report["exactMatchRate"], 1.0)
        self.assertIn("ar-EG", report["perLanguage"])
        self.assertIn("en-US", report["perLanguage"])

    def test_vision_reports_perfect_detection_metrics(self):
        report = score_vision({
            "corpus": "test",
            "images": [{
                "id": "one",
                "annotations": [{"classId": 0, "label": "person", "box": [0, 0, 10, 10]}],
                "predictions": [{"classId": 0, "label": "person", "confidence": 0.99, "box": [0, 0, 10, 10]}],
            }],
        })
        self.assertEqual(report["precision"], 1.0)
        self.assertEqual(report["recall"], 1.0)
        self.assertEqual(report["map50"], 1.0)

    def test_vision_counts_predictions_for_classes_without_ground_truth_as_false_positives(self):
        report = score_vision({
            "corpus": "test",
            "images": [{
                "id": "one",
                "annotations": [{"classId": 0, "label": "person", "box": [0, 0, 10, 10]}],
                "predictions": [
                    {"classId": 0, "label": "person", "confidence": 0.99, "box": [0, 0, 10, 10]},
                    {"classId": 1, "label": "cat", "confidence": 0.95, "box": [20, 20, 30, 30]},
                ],
            }],
        })
        self.assertEqual(report["precision"], 0.5)
        self.assertEqual(report["recall"], 1.0)
        self.assertEqual(report["perClass"]["1"]["falsePositive"], 1)
        self.assertEqual(report["map50"], 1.0)


if __name__ == "__main__":
    unittest.main()
