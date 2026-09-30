import json
from pathlib import Path
from typing import Any

VECTORS_DIR = Path(__file__).resolve().parents[2] / "shared-test-vectors"


def load_cases(domain: str, name: str) -> list[dict[str, Any]]:
    """Load a shared vector file; fail loudly if it is missing or empty."""
    path = VECTORS_DIR / domain / f"{name}.json"
    document = json.loads(path.read_text(encoding="utf-8"))
    cases: list[dict[str, Any]] = document["cases"]
    assert cases, f"{path} has no cases"
    return cases
