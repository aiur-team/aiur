#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import tempfile
tool = Path(__file__).with_name("regex_census.exs").resolve()
with tempfile.TemporaryDirectory(prefix="aiur-regex-research-") as tmp:
    root = Path(tmp)
    lib = root / "src/lib"
    lib.mkdir(parents=True)
    (lib / "fixture.ex").write_text("""
defmodule First do
  @pattern ~r/abc/
  def matcher, do: ~r/abc/i
  quote do
    @skipped ~r/abc/
  end
  defmodule Nested do
    def matcher, do: ~r/abc/
  end
  def crash, do: raise("must never execute")
end
""")
    cmd = ["elixir", str(tool), str(root)]
    first = subprocess.check_output(cmd, text=True)
    assert first == subprocess.check_output(cmd, text=True)
    data = json.loads(first)
    assert data["sigil_sites"] == 3
    assert len(data["cross_module_groups"]) == 1
    group = data["cross_module_groups"][0]
    assert group["modules"] == 2
    assert {x["module"] for x in group["sites"]} == {"First", "First.Nested"}
    assert len(group["sites"]) == 2
print("regex census: inline/attribute, flags, quote exclusion, nested modules and repeatability passed")
