#!/usr/bin/env python3
"""Guard numeric type identity in the literal candidate screen."""

import gzip
import json
import tempfile
from pathlib import Path

from inline_literal_summary import build


with tempfile.TemporaryDirectory() as folder:
    source = Path(folder) / "census.json"
    rows = []
    for index in range(3):
        rows.append({"kind": "number", "value": 100, "module": f"Int{index}",
                     "path": f"int{index}.ex", "line": 1})
        rows.append({"kind": "number", "value": 100.0, "module": f"Float{index}",
                     "path": f"float{index}.ex", "line": 1})
    source.write_text(json.dumps({"literals": rows, "files": [1] * 6}))
    assert build(source)["selected_groups"] == 0, "int and float values merged into a false five-module candidate"
    compressed = source.with_suffix(".json.gz")
    compressed.write_bytes(gzip.compress(source.read_bytes()))
    assert build(compressed)["selected_groups"] == 0, "gzip input differs from plain JSON"
