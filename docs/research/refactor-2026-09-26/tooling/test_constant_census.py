#!/usr/bin/env python3
"""Synthetic parser checks; no production source is evaluated."""
import json
from pathlib import Path
import subprocess
import tempfile
tool = Path(__file__).with_name("constant_census.exs").resolve()
with tempfile.TemporaryDirectory(prefix="aiur-constant-census-") as temp:
    root = Path(temp)
    lib = root / "src/lib"
    lib.mkdir(parents=True)
    (lib / "fixture.ex").write_text("""
defmodule Outer do
  @doc "excluded"
  @spec example() :: integer()
  @timeout 60 * 1000
  @equal_timeout 60_000
  @negative -10
  @half div(100, 2)
  @unknown System.get_env("NOT_READ")
  @bad_div div(1, 0)
  @matcher ~r/agent:(todo|done)/
  quote do
    @generated 999
  end
  defmodule Inner do
    @timeout 60_000
  end
  def example, do: raise("never execute")
end
""")
    d = json.loads(subprocess.check_output(["elixir", str(tool), str(root)], text=True))
    rows = {(x["module"], x["name"]): x for x in d["attributes"]}
    assert len(d["files"]) == 1 and len(rows) == 8, rows
    assert rows[("Outer", "timeout")]["numeric_value"] == 60000
    assert rows[("Outer", "equal_timeout")]["numeric_value"] == 60000
    assert rows[("Outer.Inner", "timeout")]["numeric_value"] == 60000
    assert rows[("Outer", "negative")]["numeric_value"] == -10
    assert rows[("Outer", "half")]["numeric_value"] == 50
    assert rows[("Outer", "unknown")]["numeric_value"] is None
    assert rows[("Outer", "bad_div")]["numeric_value"] is None
    assert rows[("Outer", "matcher")]["expression"].startswith("~r")
    assert ("Outer", "generated") not in rows and ("Outer", "doc") not in rows
print("constant census: arithmetic, symbolic values, regex, quote exclusion, nested modules and parse-only behavior passed")
