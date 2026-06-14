"""Word-geometry OCR sidecar over PaddleOCR.

One endpoint: POST /read with raw image bytes returns the recognized
text lines and their axis-aligned boxes in the image's pixel space.
The Rails app treats this exactly like its Tesseract connector; line
granularity (rather than word) is acceptable to the fuzzy matcher,
which tokenizes entries itself.

PaddleOCR's detector handles stylized display type, inverse text, and
rotated lines (textline orientation enabled) - the failure modes that
blind Tesseract on dark or decorative label artwork.
"""

import io
import json
import logging
import os
import signal
import threading
import time
import uuid
from typing import Annotated

import numpy as np
from fastapi import Body, FastAPI, Request, Response
from paddleocr import PaddleOCR
from PIL import Image, UnidentifiedImageError

# Detection cost (CPU time and the allocator's permanent high-water
# mark) scales with input area: a ~3800px read peaks past 10GB on CPU,
# and Paddle's arena keeps that high-water mark for the worker's life.
# Inputs are downscaled to this longest side before inference and the
# word boxes scaled back, so callers always receive coordinates in the
# original pixel space. Fine print lost to the cap is recovered by the
# caller's targeted region crops, which arrive here small and
# pre-magnified. Hosts with real memory (or a GPU) can raise it up to
# PaddleOCR's own 4000px detection ceiling; keep the Rails side's
# EXTRACTION_OCR_MAX_INPUT_SIDE in agreement.
MAX_SIDE = int(os.environ.get("OCR_MAX_INPUT_SIDE", "2500"))
OCR_CONCURRENCY = int(os.environ.get("OCR_CONCURRENCY", "1"))
QUEUE_TIMEOUT_SECONDS = float(os.environ.get("OCR_QUEUE_TIMEOUT_SECONDS", "2.0"))
MAX_READS = int(os.environ.get("OCR_MAX_READS", "0"))
STARTED_AT = time.time()

app = FastAPI()
logger = logging.getLogger("ocr_service")
logger.setLevel(os.environ.get("OCR_LOG_LEVEL", "INFO"))
logger.propagate = False
if not logger.handlers:
    log_handler = logging.StreamHandler()
    log_handler.setFormatter(logging.Formatter("%(message)s"))
    logger.addHandler(log_handler)
read_semaphore = threading.BoundedSemaphore(OCR_CONCURRENCY)
state_lock = threading.Lock()
state = {
    "accepted": 0,
    "completed": 0,
    "failed": 0,
    "rejected_busy": 0,
    "active": 0,
    "total_words": 0,
    "last_error": None,
    "last_success_at": None,
    "shutdown_scheduled": False,
}

# Model weights download on first construction; doc-level rectification
# stays off (labels are flat artwork, not photographed documents).
# The mobile detector is the default: the server variant's activation
# footprint on CPU is multi-gigabyte per read and was the source of the
# worker's memory pathology; mobile detects with a fraction of both
# memory and time, and the caller's region-crop ladder compensates for
# its weaker small-print recall.
DET_MODEL = os.environ.get("OCR_DET_MODEL", "PP-OCRv5_mobile_det")

engine = PaddleOCR(
    lang="en",
    text_detection_model_name=DET_MODEL,
    use_doc_orientation_classify=False,
    use_doc_unwarping=False,
    use_textline_orientation=True,
)


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True}


@app.get("/readyz")
def readyz(response: Response) -> dict:
    metrics = snapshot_metrics()
    ok = not metrics["reads"]["shutdown_scheduled"]
    response.status_code = 200 if ok else 503
    return {
        "ok": ok,
        "engine_loaded": engine is not None,
        "reads": metrics["reads"],
    }


@app.get("/metrics")
def metrics() -> dict:
    return snapshot_metrics()


@app.post("/read")
def read(request: Request, response: Response, body: Annotated[bytes, Body(media_type="application/octet-stream")]) -> dict:
    request_id = request.headers.get("x-request-id") or uuid.uuid4().hex
    queued_at = time.monotonic()
    if not read_semaphore.acquire(timeout=QUEUE_TIMEOUT_SECONDS):
        record_busy()
        response.status_code = 429
        response.headers["Retry-After"] = str(max(1, round(QUEUE_TIMEOUT_SECONDS)))
        log_event({
            "event": "ocr_read_rejected_busy",
            "request_id": request_id,
            "queue_wait_ms": elapsed_ms(queued_at),
        })
        return {"error": "ocr sidecar busy", "request_id": request_id}

    queue_wait_ms = elapsed_ms(queued_at)
    record_accept()
    started_at = time.monotonic()
    try:
        image = Image.open(io.BytesIO(body)).convert("RGB")
    except (UnidentifiedImageError, OSError) as error:
        record_failure(error)
        response.status_code = 422
        read_semaphore.release()
        log_event({
            "event": "ocr_read_failed",
            "request_id": request_id,
            "error_class": error.__class__.__name__,
            "error": str(error)[:200],
            "duration_ms": elapsed_ms(started_at),
        })
        return {"error": "body is not a decodable image", "request_id": request_id}

    width, height = image.size
    scale = 1.0
    if max(width, height) > MAX_SIDE:
        scale = MAX_SIDE / max(width, height)
        image = image.resize(
            (max(1, round(width * scale)), max(1, round(height * scale))),
            Image.LANCZOS,
        )

    try:
        words = read_words(image, scale)
    except (RuntimeError, TypeError, ValueError, OSError) as error:
        record_failure(error)
        response.status_code = 500
        log_event({
            "event": "ocr_read_failed",
            "request_id": request_id,
            "error_class": error.__class__.__name__,
            "error": str(error)[:200],
            "duration_ms": elapsed_ms(started_at),
        })
        schedule_shutdown_if_needed()
        return {"error": "ocr inference failed", "request_id": request_id}
    finally:
        read_semaphore.release()

    record_success(len(words))
    duration_ms = elapsed_ms(started_at)
    log_event({
        "event": "ocr_read_completed",
        "request_id": request_id,
        "duration_ms": duration_ms,
        "queue_wait_ms": queue_wait_ms,
        "input_width": width,
        "input_height": height,
        "scaled_width": image.size[0],
        "scaled_height": image.size[1],
        "words": len(words),
    })
    schedule_shutdown_if_needed()
    return {"width": width, "height": height, "words": words}


def read_words(image: Image.Image, scale: float) -> list[dict[str, object]]:
    words = []
    for page in engine.predict(np.array(image)):
        texts = page.get("rec_texts") or []
        scores = page.get("rec_scores") or []
        boxes = page.get("rec_boxes")
        polys = page.get("rec_polys")
        for index, text in enumerate(texts):
            if not str(text).strip():
                continue
            if boxes is not None and len(boxes) > index:
                x1, y1, x2, y2 = (int(v) for v in boxes[index])
            else:
                xs = [int(p[0]) for p in polys[index]]
                ys = [int(p[1]) for p in polys[index]]
                x1, y1, x2, y2 = min(xs), min(ys), max(xs), max(ys)
            word = {
                "text": str(text),
                "x": round(x1 / scale),
                "y": round(y1 / scale),
                "width": round((x2 - x1) / scale),
                "height": round((y2 - y1) / scale),
            }
            if len(scores) > index:
                word["confidence"] = float(scores[index])
            words.append(word)
    return words


def snapshot_metrics() -> dict[str, object]:
    with state_lock:
        reads = dict(state)
    return {
        "ok": True,
        "pid": os.getpid(),
        "uptime_seconds": round(time.time() - STARTED_AT, 3),
        "configuration": {
            "ocr_concurrency": OCR_CONCURRENCY,
            "queue_timeout_seconds": QUEUE_TIMEOUT_SECONDS,
            "max_reads": MAX_READS,
            "max_input_side": MAX_SIDE,
            "det_model": DET_MODEL,
        },
        "reads": reads,
    }


def record_accept() -> None:
    with state_lock:
        state["accepted"] += 1
        state["active"] += 1


def record_busy() -> None:
    with state_lock:
        state["rejected_busy"] += 1


def record_success(word_count: int) -> None:
    with state_lock:
        state["completed"] += 1
        state["active"] -= 1
        state["total_words"] += word_count
        state["last_success_at"] = time.time()


def record_failure(error: BaseException) -> None:
    with state_lock:
        state["failed"] += 1
        state["active"] -= 1
        state["last_error"] = {
            "class": error.__class__.__name__,
            "message": str(error)[:200],
        }


def schedule_shutdown_if_needed() -> None:
    with state_lock:
        completed = state["completed"]
        failed = state["failed"]
        already_scheduled = state["shutdown_scheduled"]
        should_shutdown = MAX_READS > 0 and completed + failed >= MAX_READS
        if not should_shutdown or already_scheduled:
            return
        state["shutdown_scheduled"] = True

    thread = threading.Thread(target=shutdown_after_response, daemon=True)
    thread.start()


def shutdown_after_response() -> None:
    time.sleep(0.25)
    os.kill(os.getpid(), signal.SIGTERM)


def elapsed_ms(started_at: float) -> float:
    return round((time.monotonic() - started_at) * 1000.0, 2)


def log_event(payload: dict[str, object]) -> None:
    logger.info(json.dumps(payload, sort_keys=True))
