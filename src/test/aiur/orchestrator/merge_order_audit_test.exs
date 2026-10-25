defmodule Aiur.Orchestrator.MergeOrderAuditTest do
  use ExUnit.Case, async: true
  alias Aiur.Orchestrator.{MergeOrderAudit, State}

  defp event(number), do: %{topic: "ticket.9.pr.merged", pr: %{"number" => number, "head" => %{"sha" => "headsha"}}}

  defp opts(blockers, status \\ {:ok, "ahead"}) do
    parent = self()

    [
      blockers: fn "9" -> blockers end,
      compare: fn _sha, "headsha" -> status end,
      emit: fn topic, alert -> send(parent, {:alert, topic, alert}) end
    ]
  end

  test "a merge with an open blocker raises one critical alert, deduped per PR" do
    open = [%{id: "5", pr: %{merged?: false, state: :open}}]
    state = MergeOrderAudit.merged(%State{}, "9", event(20), opts(open))
    assert_received {:alert, "ticket.9.merge.out-of-order", alert}
    assert alert[:severity] == "critical"
    assert alert[:message] =~ "#5"

    MergeOrderAudit.merged(state, "9", event(20), opts(open))
    refute_received {:alert, _, _}
  end

  test "a merged blocker that is not contained alerts; a contained one does not" do
    merged = [%{id: "5", pr: %{merged?: true, merge_commit_sha: "sha5"}}]
    MergeOrderAudit.merged(%State{}, "9", event(21), opts(merged, {:ok, "diverged"}))
    assert_received {:alert, _, [_, _, {:severity, "critical"}]}

    MergeOrderAudit.merged(%State{}, "9", event(22), opts(merged, {:ok, "ahead"}))
    refute_received {:alert, _, _}
  end

  test "missing facts or a failed compare warn instead of passing silently" do
    MergeOrderAudit.merged(%State{}, "9", event(23), opts([%{id: "5", pr: nil}]))
    assert_received {:alert, _, alert}
    assert alert[:severity] == "warning"
    assert alert[:message] =~ "could not verify"

    merged = [%{id: "5", pr: %{merged?: true, merge_commit_sha: "sha5"}}]
    MergeOrderAudit.merged(%State{}, "9", event(24), opts(merged, {:error, :boom}))
    assert_received {:alert, _, [_, _, {:severity, "warning"}]}
  end

  test "an event without a PR number audits nothing" do
    assert MergeOrderAudit.merged(%State{}, "9", %{topic: "ticket.9.pr.merged"}, opts([%{id: "5", pr: nil}])) == %State{}
    refute_received {:alert, _, _}
  end
end
