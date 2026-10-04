"""A cheap check that a file's first bytes fit its declared type (not a virus scan)."""

OLE = bytes.fromhex("d0cf11e0a1b11ae1")
ZIP_HEADS = (b"PK\x03\x04", b"PK\x05\x06")
HEAD_BYTES = 1024
NEEDED = 12  # bytes needed to decide


def looks_like(mime: str, head: bytes) -> bool:
    if mime == "image/jpeg":
        return head.startswith(b"\xff\xd8\xff")
    if mime == "image/png":
        return head.startswith(b"\x89PNG\r\n\x1a\n")
    if mime == "image/webp":
        return head[:4] == b"RIFF" and head[8:12] == b"WEBP"
    if mime in ("image/heic", "image/heif"):
        return head[4:8] == b"ftyp"
    if mime == "application/pdf":
        return b"%PDF-" in head[:HEAD_BYTES]
    if mime in ("application/msword", "application/vnd.ms-excel", "application/vnd.ms-powerpoint"):
        return head.startswith(OLE)
    if mime == "text/plain":
        return b"\x00" not in head
    return head.startswith(ZIP_HEADS)  # docx, xlsx, pptx, zip
