defmodule Aiur.AiurRunAuthoritySkillTest do
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)

  test "debug evidence never implies external issue mutation authority" do
    skill = read(".claude/skills/aiur-run/SKILL.md")
    executor = read(".claude/skills/aiur-run/references/executor.md")

    assert skill =~ "Record external issue\nmutation authority separately"
    assert skill =~ "controls evidence capture and never"
    assert skill =~ "separately\nrecorded authority"
    assert executor =~ "`--debug` controls evidence capture only"
    assert executor =~ "never grants\nauthority to create or comment"
    assert executor =~ "requires separate, explicit\nauthority recorded"

    for source <- [skill, executor] do
      refute source =~ "standing consent"
      refute source =~ "debug run:"
      refute source =~ "non-debug run:"
      refute source =~ "file a sanitized Aiur bug automatically"
    end
  end

  defp read(path), do: File.read!(Path.join(@repo_root, path))
end
