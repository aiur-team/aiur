defmodule Aiur.AiurDebugSkillTest do
  @moduledoc """
  Contract coverage for the canonical `/aiur-debug` context overlay.

  The skill is operational documentation, so these tests protect discovery,
  composition boundaries, required diagnostic scope, link integrity, and safe
  portable examples rather than duplicating prose line-for-line.
  """
  use ExUnit.Case, async: true

  @repo_root Path.expand("../../..", __DIR__)
  @skill Path.join(@repo_root, ".claude/skills/aiur-debug")
  @references ~w(evidence-and-correlation.md diagnostic-recipes.md examples-and-reporting.md)

  test "has valid metadata and one canonical reference tree" do
    skill = read("SKILL.md")

    assert skill =~ ~r/\A---\nname: aiur-debug\ndescription: .+\n---\n/

    for reference <- @references do
      assert skill =~ "(#{reference})"
      assert File.regular?(Path.join(@skill, reference))
    end

    assert {"", 0} =
             System.cmd("git", ["-C", @repo_root, "ls-files", ".codex/skills/debug/SKILL.md"]),
           "the narrow repo-local /debug skill would conflict with the canonical overlay"
  end

  test "stays an Aiur overlay and capability-detects general companions" do
    skill = read("SKILL.md")
    examples = read("examples-and-reporting.md")

    assert skill =~ "Aiur context overlay"
    assert skill =~ "Inspect the active skill/capability catalog"
    assert skill =~ "native `/debug`"
    assert skill =~ "If `/ce-debug` is available"
    assert skill =~ "provider exposes a native diagnostic skill or capability"
    assert skill =~ "never hard-depends on Compound Engineering"

    for delegated <- ["reproduction", "hypothesis testing", "causal-chain analysis", "fix validation"] do
      assert skill =~ delegated
    end

    for companion <- ["native `/debug`", "`/ce-debug`"] do
      assert examples =~ companion
    end
  end

  test "covers the evidence map, correlation hierarchy, and duplicate proof" do
    evidence = read("evidence-and-correlation.md")

    for source <- [
          "Operator checkout",
          "Runtime application log",
          "Historical/rotated runtime logs",
          "Workspace event stream",
          "Debug chat recording",
          "BEAM/control RPC",
          "Native blockers/parents",
          "Provider lifecycle",
          "Alerts/decisions/events"
        ] do
      assert evidence =~ source
    end

    for key <- [
          "repository/ticket",
          "run/instance",
          "session/turn/item",
          "event/delivery",
          "agent_process_group_id",
          "head SHA",
          "base SHA"
        ] do
      assert evidence =~ key
    end

    assert evidence =~ "Distinct `item`/tool-call IDs prove the agent invoked the command twice"
    assert evidence =~ "identical item or event identity replayed"
    assert evidence =~ "normalized UTC timestamp"
    assert evidence =~ "Millisecond ordering across hosts is not guaranteed"
    assert evidence =~ "current `Aiur.LogFile` does not"
    assert evidence =~ "--glob 'aiur.log*'"
    assert evidence =~ "Process evidence is namespace-scoped"
    assert evidence =~ "absence in a sandbox-local `ps` is not counter-evidence"
  end

  test "provides ten read-only-first recipes with evidence gates and safe recovery" do
    recipes = read("diagnostic-recipes.md")

    for number <- 1..10 do
      assert recipes =~ ~r/^## #{number}\. /m, "missing recipe #{number}"
    end

    assert length(Regex.scan(~r/^\*\*Read-only first\*\*/m, recipes)) == 10
    assert length(Regex.scan(~r/^\*\*Classify \/ stop\*\*/m, recipes)) == 10
    assert length(Regex.scan(~r/^\*\*Safest recovery escalation\*\*/m, recipes)) == 10

    for guardrail <- [
          "blast radius",
          "preserve",
          "hard reset",
          "many children",
          "Mix/build-gate",
          "non-loopback",
          "`.git-writable`",
          "deduplication defect"
        ] do
      assert String.downcase(recipes) =~ String.downcase(guardrail)
    end

    assert recipes =~ "An issue-agent sandbox can see only its own namespace"
    assert recipes =~ "operator context or another host-level capability"
    assert recipes =~ "Observation scope (`issue sandbox` or `host/operator`)"
  end

  test "includes all worked examples plus reporting and sanitization" do
    report = read("examples-and-reporting.md")

    for heading <- [
          "duplicated test command",
          "tracker-paused ticket",
          "no dashboard listener on a non-loopback bind",
          "genuine orchestrator retry/replay defect",
          "Concise diagnostic report",
          "Sanitized bug-report checklist"
        ] do
      assert report =~ heading
    end

    assert report =~ "fix in owning ticket | defer P2/P3 | independent reproducible P0/P1 issue"
    assert report =~ "No secrets, credentials, tokens"
    assert report =~ "Repository-relative paths"
  end

  test "cross-links maintained Aiur guidance and avoids machine-specific examples" do
    all = Enum.map_join(["SKILL.md" | @references], "\n", &read/1)

    for link <- [
          "../aiur-run/SKILL.md",
          "../aiur-monitor/SKILL.md",
          "../using-aiur/SKILL.md",
          "../aiur-agent/SKILL.md",
          "../../../AGENTS.md#manual-testing--the-only-definition",
          "../../../src/docs/logging.md"
        ] do
      assert all =~ link
    end

    refute all =~ ~r{/(?:home|Users)/[^/\s]+/}
    refute all =~ ~r/\b(?:10|192\.168)\.\d{1,3}\.\d{1,3}/
    refute all =~ ~r/\bgh[pousr]_[A-Za-z0-9]{20,}\b/
    refute all =~ ~r/\bsk-[A-Za-z0-9]{20,}\b/
    refute all =~ ~r/(^|\s)grep\s/
  end

  defp read(file), do: File.read!(Path.join(@skill, file))
end
