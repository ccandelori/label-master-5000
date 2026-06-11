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
import os

import numpy as np
from fastapi import FastAPI, Request, Response
from paddleocr import PaddleOCR
from PIL import Image

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

app = FastAPI()

# Model weights download on first construction; doc-level rectification
# stays off (labels are flat artwork, not photographed documents).
engine = PaddleOCR(
    lang="en",
    use_doc_orientation_classify=False,
    use_doc_unwarping=False,
    use_textline_orientation=True,
)


@app.get("/healthz")
def healthz() -> dict:
    return {"ok": True}


@app.post("/read")
async def read(request: Request, response: Response) -> dict:
    data = await request.body()
    try:
        image = Image.open(io.BytesIO(data)).convert("RGB")
    except Exception:
        response.status_code = 422
        return {"error": "body is not a decodable image"}

    width, height = image.size
    scale = 1.0
    if max(width, height) > MAX_SIDE:
        scale = MAX_SIDE / max(width, height)
        image = image.resize(
            (max(1, round(width * scale)), max(1, round(height * scale))),
            Image.LANCZOS,
        )

    words = []
    for page in engine.predict(np.array(image)):
        texts = page.get("rec_texts") or []
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
            words.append(
                {
                    "text": str(text),
                    "x": round(x1 / scale),
                    "y": round(y1 / scale),
                    "width": round((x2 - x1) / scale),
                    "height": round((y2 - y1) / scale),
                }
            )

    return {"width": width, "height": height, "words": words}
