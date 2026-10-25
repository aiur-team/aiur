defmodule Aiur.AiurAgentSkillDefectDispositionTest do
  use ExUnit.Case, async: true

  @conventions Path.expand("../../../.claude/skills/aiur-agent/conventions.md", __DIR__)

  # #4521: worker-filed defects parked in needs-triage were invisible to dispatch.
  test "worker-filed defects with evidence are filed dispatchable; needs-triage is for human decisions" do
    [_, section] = @conventions |> File.read!() |> String.split("## Out-of-scope findings", parts: 2)
    [section | _] = String.split(section, "\n## ", parts: 2)
    section = String.replace(section, ~r/\s+/, " ")

    assert section =~ "a defect with evidence — the command and its output, a CI run id, or a file and line reference — gets `agent:todo`"
    assert section =~ "only a finding that needs a human decision"
    refute section =~ "apply `needs-triage` in that same creation request so the user triages it before any agent picks it up"
  end
end
