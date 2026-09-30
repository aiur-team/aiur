#!/usr/bin/env python3
"""Guard the parse-only inline census against token-metadata false positives."""

import json
import subprocess
import tempfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("inline_literal_census.exs")


def main():
    with tempfile.TemporaryDirectory(prefix="aiur-inline-census-") as temp:
        source = Path(temp) / "src/lib/sample.ex"
        source.parent.mkdir(parents=True)
        source.write_text(
            "defmodule Sample do\n"
            "  @limit 42\n"
            "  def value(input), do: {input, \"ticket.\", 7}\n"
            "  def quoted, do: quote(do: {\"generated\", 900})\n"
            "end\n"
        )
        result = subprocess.check_output(["elixir", str(SCRIPT), temp], text=True)
        data = json.loads(result)
        assert len(data["files"]) == 1
        assert [(row["kind"], row["value"]) for row in data["literals"]] == [
            ("string", "ticket."),
            ("number", 7),
        ], data["literals"]


if __name__ == "__main__":
    main()
