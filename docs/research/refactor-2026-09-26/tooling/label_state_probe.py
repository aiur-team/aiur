#!/usr/bin/env python3
"""Run frozen pure helper slices; no Mix, daemon, network, or production writes."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

p = argparse.ArgumentParser()
p.add_argument("snapshot", type=Path)
p.add_argument("--elixir", default="elixir")
args = p.parse_args()
sources = {}
def read(path):
    text = (args.snapshot / path).read_text()
    sources[path] = hashlib.sha256(text.encode()).hexdigest()
    return text
def section(text, start, stop):
    assert text.count(start) == 1 and text.count(stop) == 1
    return text.split(start, 1)[1].split(stop, 1)[0]
state = read("src/lib/aiur/orchestrator/state.ex")
events = read("src/lib/aiur/agent_events.ex")
issue = read("src/lib/aiur/issue.ex")
summaries = read("src/lib/aiur/agent_list/summaries.ex")
label_names = section(issue, "  @spec label_names(t()) :: [String.t()]\n", "  @spec paused?(t())")
issue_tag = section(state, "  @spec issue_tag(term()) :: String.t() | nil\n", "  @spec find_running_by_identifier")
summary = section(events, "  @spec agent_summary(agent_identifier(), atom(), non_neg_integer(), map()) :: agent_summary()\n", '  @doc """\n  Canonical emoji')
script = (
    "defmodule Aiur.Issue do\n defstruct labels: []\n" + label_names + "end\n"
    + "defmodule ProbeState do\n alias Aiur.Issue\n" + issue_tag + "end\n"
    + "defmodule ProbeEvents do\n" + summary + "end\n"
    + summaries + """
row = fn labels ->
  issue = struct(Aiur.Issue, labels: labels)
  ProbeEvents.agent_summary("1", :queued, 0, %{tag: ProbeState.issue_tag(issue), work_state: :idle})
end
cases = [
  {"default_done", ["agent:done"], false, "agent:done"},
  {"custom_done", ["custom:done"], true, nil},
  {"marker_before_done", ["agent:watch", "agent:done"], true, "agent:watch"},
  {"done_before_marker", ["agent:done", "agent:watch"], false, "agent:done"}
]
Enum.each(cases, fn {name, labels, visible, tag} ->
  summary = row.(labels)
  actual = Aiur.AgentList.Summaries.visible_summaries([summary]) != []
  if actual != visible or Map.get(summary, :tag) != tag, do: raise(name)
  IO.puts(name <> ": visible=" <> to_string(actual) <> " tag=" <> inspect(Map.get(summary, :tag)))
end)
string = %{identifier: "1", status: :running, work_state: "paused"}
atom = %{identifier: "2", status: :running, work_state: :paused}
true = Aiur.AgentList.Summaries.paused?(string)
true = Aiur.AgentList.Summaries.paused?(atom)
["2", "1"] = Enum.map(Aiur.AgentList.Summaries.visible_summaries([string, atom]), & &1.identifier)
IO.puts("string_paused: predicate=true; sort after atom_paused despite lower identifier")
"""
)
with tempfile.TemporaryDirectory(prefix="aiur-label-research-") as temp:
    path = Path(temp) / "probe.exs"
    path.write_text(script)
    result = subprocess.run([args.elixir, str(path)], text=True, capture_output=True, check=True)
print(json.dumps({
    "status": "passed",
    "method": "Compile exact frozen helper slices and the full pure Summaries module in an isolated Elixir process. Minimal Issue struct; actual label_names helper. No full StatusReport or poll pipeline execution.",
    "sources": sources,
    "observations": result.stdout.splitlines(),
    "limits": "Synthetic helper boundary inputs establish deterministic behavior, not production prevalence, end-to-end reachability, or manual TUI verification. String work_state producer reachability remains open."
}, indent=2))
