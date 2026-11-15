"""Image attachments for vision turns (e.g. the screenshot the app sends).

An attachment is {"media_type": "image/png", "data": "<base64>"}; providers turn
it into their own wire format. Validation happens here so a bad file fails
before any API call.
"""

from __future__ import annotations

import base64
from pathlib import Path

MEDIA_TYPES = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".webp": "image/webp",
}
MAX_ENCODED_BYTES = 5 * 1024 * 1024   # Anthropic's per-image API limit


class ImageError(ValueError):
    pass


def load_image(path: str | Path) -> dict:
    p = Path(path).expanduser()
    if not p.is_file():
        raise ImageError(f"image not found: {p}")
    media_type = MEDIA_TYPES.get(p.suffix.lower())
    if media_type is None:
        raise ImageError(f"unsupported image type {p.suffix!r} (use png, jpeg, gif or webp)")
    data = base64.b64encode(p.read_bytes()).decode("ascii")
    if len(data) > MAX_ENCODED_BYTES:
        raise ImageError(f"image is too large ({len(data) // 1024} KB encoded; limit is 5 MB)")
    return {"media_type": media_type, "data": data}
