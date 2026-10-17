"""Canonical experiment JSON and content hashes, independent of wall time."""

import hashlib
import json
import math

from .numeric import round_sig


def rounded(value):
    if isinstance(value, float):
        return round_sig(value) if math.isfinite(value) else None
    if isinstance(value, dict):
        return {key: rounded(item) for key, item in value.items()}
    if isinstance(value, list):
        return [rounded(item) for item in value]
    return value


def encode(value):
    return json.dumps(rounded(value), sort_keys=True, ensure_ascii=False,
                      allow_nan=False, indent=2) + "\n"


def input_hash(value):
    # Hash full precision input, never the rounded result representation.
    data = json.dumps(value, sort_keys=True, ensure_ascii=False,
                      allow_nan=False, separators=(",", ":"))
    return hashlib.sha256(data.encode("utf-8")).hexdigest()
