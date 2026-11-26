defmodule Aiur.AgentRunner.StoppedSessionPromptTest do
  use ExUnit.Case, async: true

  alias Aiur.AgentRunner.TurnPrompt
  alias Aiur.Issue

  test "status listing keeps the first 200 lines and reports the remaining count" do
    workspace = Path.join(System.tmp_dir!(), "stopped-many-untracked-#{System.unique_integer([:positive])}")
    File.mkdir_p!(workspace)
    {_, 0} = System.cmd("git", ["-C", workspace, "init", "--quiet"])
    {_, 0} = System.cmd("git", ["-C", workspace, "-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "--allow-empty", "-m", "initial", "--quiet"])
    Enum.each(1..1_000, fn number -> File.write!(Path.join(workspace, "untracked-#{number}.txt"), "") end)
    on_exit(fn -> Aiur.TestCleanup.rm_rf!(workspace) end)

    issue = %Issue{id: "5830", identifier: "5830", title: "Bound resume context", state: "in-progress"}
    prompt = TurnPrompt.build_turn_prompt(issue, [prior_work: true, workspace: workspace], 1, nil)
    [status_section] = Regex.scan(~r/`git status --short` in the kept workspace:\n```text\n(.*?)\n```/s, prompt)
    [_full, status_lines] = status_section
    lines = String.split(status_lines, "\n")

    assert length(lines) == 201
    assert Enum.take(lines, 200) |> Enum.all?(&String.starts_with?(&1, "?? "))
    assert List.last(lines) == "… 800 more"
  end
end
