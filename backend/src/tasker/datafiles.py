"""Shared data files (``shared-data/``): the repository copy, or ``SHARED_DATA_DIR`` (container).

The api image carries only ``backend/src``; compose mounts the repository's ``shared-data``
read-only and points ``SHARED_DATA_DIR`` at it.
"""

import json
import os
from functools import cache
from pathlib import Path
from typing import Any


def shared_data_dir() -> Path:
    override = os.environ.get("SHARED_DATA_DIR", "").strip()
    if override:
        return Path(override)
    return Path(__file__).resolve().parents[3] / "shared-data"


@cache
def load_json(relative: str) -> Any:
    """A JSON file under ``shared-data`` (cached: the files change only with a release)."""
    return json.loads((shared_data_dir() / relative).read_text(encoding="utf-8"))
