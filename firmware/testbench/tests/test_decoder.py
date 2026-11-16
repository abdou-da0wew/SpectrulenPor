import sys
import unittest
from types import ModuleType, SimpleNamespace
from unittest.mock import Mock, patch

from testbench.errors import TestbenchError
from testbench.transport import WIRE, jpeg_dimensions


class DecoderTests(unittest.TestCase):
    def test_markers_alone_never_count_as_decoded(self):
        package = ModuleType("PIL")
        package.Image = SimpleNamespace(open=Mock(side_effect=ValueError("raw decoder detail")))
        with patch.dict(sys.modules, {"PIL": package}), self.assertRaises(TestbenchError) as caught:
            jpeg_dimensions(b"\xff\xd8not-an-image\xff\xd9")
        self.assertEqual(caught.exception.code, "TB_INVALID_JPEG")
        package.Image.open.assert_called_once()

    def test_decoder_load_and_format_are_required(self):
        image = Mock()
        image.format, image.width, image.height, image.size = "JPEG", 800, 600, (800, 600)
        context = Mock()
        context.__enter__ = Mock(return_value=image)
        context.__exit__ = Mock(return_value=False)
        package = ModuleType("PIL")
        package.Image = SimpleNamespace(open=Mock(return_value=context))
        with patch.dict(sys.modules, {"PIL": package}):
            self.assertEqual(jpeg_dimensions(b"\xff\xd8image\xff\xd9"), (800, 600))
        image.load.assert_called_once()

    def test_oversize_and_wrong_markers_rejected_before_decoder(self):
        for data in (b"", b"image", b"\xff\xd8missing-end", b"\xff\xd8" + b"x" * WIRE.MAX_FRAME_BYTES + b"\xff\xd9"):
            with self.assertRaises(TestbenchError):
                jpeg_dimensions(data)

    def test_missing_decoders_is_explicit_dependency_error(self):
        with patch.dict(sys.modules, {"PIL": None, "cv2": None}), self.assertRaises(TestbenchError) as caught:
            jpeg_dimensions(b"\xff\xd8image\xff\xd9")
        self.assertEqual(caught.exception.code, "TB_JPEG_DECODER_MISSING")


if __name__ == "__main__":
    unittest.main()
