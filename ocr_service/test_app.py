import importlib.util
import io
import os
import sys
import threading
import types
import unittest
import warnings
from pathlib import Path

warnings.filterwarnings(
    "ignore",
    message="Using `httpx` with `starlette.testclient` is deprecated.*",
)

from fastapi.testclient import TestClient
from PIL import Image


class BlockingEngine:
    def __init__(self):
        self.calls = 0
        self.first_read_started = threading.Event()
        self.release_first_read = threading.Event()

    def predict(self, _image):
        self.calls += 1
        if self.calls == 1:
            self.first_read_started.set()
            self.release_first_read.wait(timeout=2)
        return [
            {
                "rec_texts": ["HELLO"],
                "rec_scores": [0.91],
                "rec_boxes": [[1, 2, 11, 22]],
                "rec_polys": None,
            }
        ]


class ScoredEngine:
    def predict(self, _image):
        return [
            {
                "rec_texts": ["HELLO"],
                "rec_scores": [0.87],
                "rec_boxes": [[1, 2, 11, 22]],
                "rec_polys": None,
            }
        ]


def png_bytes():
    output = io.BytesIO()
    Image.new("RGB", (20, 20), "white").save(output, format="PNG")
    return output.getvalue()


def load_app_module(engine):
    os.environ["OCR_CONCURRENCY"] = "1"
    os.environ["OCR_QUEUE_TIMEOUT_SECONDS"] = "0.01"
    os.environ["OCR_MAX_READS"] = "0"
    os.environ["OCR_LOG_LEVEL"] = "CRITICAL"
    fake_paddleocr = types.ModuleType("paddleocr")
    fake_paddleocr.PaddleOCR = lambda **_kwargs: engine
    sys.modules["paddleocr"] = fake_paddleocr
    sys.modules.pop("ocr_sidecar_under_test", None)
    spec = importlib.util.spec_from_file_location(
        "ocr_sidecar_under_test", Path(__file__).with_name("app.py")
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["ocr_sidecar_under_test"] = module
    spec.loader.exec_module(module)
    return module


class OcrSidecarTest(unittest.TestCase):
    def test_readyz_and_metrics_are_available_without_counting_as_reads(self):
        module = load_app_module(BlockingEngine())
        client = TestClient(module.app)

        self.assertEqual({"ok": True}, client.get("/healthz").json())
        self.assertTrue(client.get("/readyz").json()["ok"])
        metrics = client.get("/metrics").json()

        self.assertEqual(0, metrics["reads"]["accepted"])
        self.assertEqual(0, metrics["reads"]["completed"])
        self.assertEqual(1, metrics["configuration"]["ocr_concurrency"])

    def test_busy_sidecar_rejects_immediately_instead_of_queueing_unbounded_work(self):
        engine = BlockingEngine()
        module = load_app_module(engine)
        client = TestClient(module.app)

        def first_read():
            client.post("/read", content=png_bytes())

        thread = threading.Thread(target=first_read)
        thread.start()
        self.assertTrue(engine.first_read_started.wait(timeout=2))

        response = client.post("/read", content=png_bytes())
        engine.release_first_read.set()
        thread.join(timeout=2)

        self.assertEqual(429, response.status_code)
        self.assertEqual("ocr sidecar busy", response.json()["error"])
        metrics = client.get("/metrics").json()
        self.assertEqual(1, metrics["reads"]["rejected_busy"])

    def test_read_response_includes_confidence_when_engine_returns_scores(self):
        module = load_app_module(ScoredEngine())
        client = TestClient(module.app)

        response = client.post("/read", content=png_bytes())

        self.assertEqual(200, response.status_code)
        word = response.json()["words"][0]
        self.assertEqual("HELLO", word["text"])
        self.assertAlmostEqual(0.87, word["confidence"])


if __name__ == "__main__":
    unittest.main()
