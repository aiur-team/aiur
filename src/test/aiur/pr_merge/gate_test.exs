defmodule Aiur.PrMerge.GateTest do
  use ExUnit.Case, async: true
  alias Aiur.PrMerge.Gate
  @head String.duplicate("a", 40)

  defp pr(attrs \\ %{}) do
    Map.merge(
      %{
        head: @head,
        state: "OPEN",
        draft: false,
        conflict: false,
        approved: true,
        bypass: false,
        title: "change",
        body: "",
        passed: ["lint"],
        required: ["lint"],
        failed: [],
        pending: [],
        full_ci: false
      },
      attrs
    )
  end

  defp policy(attrs \\ %{}), do: Map.merge(%{ci: "wait", local_tests: "partial", main_watch: %{enabled: true}, attribution_scan: false}, attrs)
  defp opts(attrs \\ %{}), do: Map.merge(%{reviewed_sha: @head, approve_body: nil, inherited: []}, attrs)

  defp evidence(head) do
    "## Local tests\nPolicy: partial\nTested head: #{head}\nBase: origin/main @ #{@head}\nSelection: changed modules\n- `mix test` -> passed\n"
  end

  test "wait refuses required checks missing from the rollup" do
    assert Gate.refusals(pr(%{required: ["lint", "coverage"]}), policy(), opts()) == ["waiting for CI (policy ci=wait)"]
  end

  test "pending_ok never permits a failed check" do
    reasons = Gate.refusals(pr(%{failed: ["coverage (2/4)"]}), policy(%{ci: "pending_ok"}), opts())
    assert "CI failed: coverage (2/4)" in reasons
  end

  test "early merge requires a watcher and local evidence at this head" do
    for {body, watch, mode} <- [{"", true, "partial"}, {evidence(String.duplicate("b", 40)), true, "partial"}, {evidence(@head), false, "partial"}, {evidence(@head), true, "none"}] do
      assert Gate.refusals(pr(%{body: body, required: ["coverage"]}), policy(%{ci: "pending_ok", main_watch: %{enabled: watch}, local_tests: mode}), opts()) ==
               ["no local-test evidence for #{@head}; wait for CI"]
    end

    assert Gate.refusals(pr(%{body: evidence(@head), required: ["coverage"]}), policy(%{ci: "pending_ok"}), opts()) == []
  end

  test "full CI overrides fresh local evidence" do
    assert "full CI required (labels or changed paths)" in Gate.refusals(pr(%{required: ["coverage"], body: evidence(@head), full_ci: true}), policy(%{ci: "pending_ok"}), opts())
  end

  test "passed required checks need no local evidence and ignore optional pending checks" do
    assert Gate.refusals(pr(%{pending: ["optional"]}), policy(%{ci: "pending_ok"}), opts()) == []
  end

  test "unverified inherited overrides refuse even if the check later passes" do
    assert Gate.refusals(pr(), policy(), opts(%{inherited: ["lint"]})) == ["inherited failure not verified by base watcher: lint"]
  end

  test "head movement and draft are both explained" do
    assert Gate.refusals(pr(%{draft: true, head: "new"}), policy(), opts()) == ["head moved: reviewed #{@head}, current new", "draft PR"]
  end

  test "closed and conflicting PRs refuse" do
    assert Gate.refusals(pr(%{state: "CLOSED", conflict: true}), policy(), opts()) == ["PR is not open", "conflict"]
  end

  test "approval at the current head is required even with bypass or a planned review" do
    assert Gate.refusals(pr(%{approved: false}), policy(), opts()) == ["approval at current head required"]
    assert Gate.refusals(pr(%{approved: false, bypass: true}), policy(), opts()) == ["approval at current head required"]
    assert Gate.refusals(pr(%{approved: false, author_id: 3, operator_id: 5}), policy(), opts(%{approve_body: "Reviewed"})) == ["approval at current head required"]
  end

  test "attribution scan covers title and body case insensitively" do
    assert Gate.refusals(pr(%{title: "CLAUDE-SESSION", body: "Generated with [Claude"}), policy(%{attribution_scan: true}), opts()) ==
             ["attribution scan: generated with [claude", "attribution scan: claude-session"]
  end
end
