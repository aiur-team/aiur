defmodule Aiur.AgentRunner.HandoffBodyGateTest do
  use Aiur.TestSupport

  alias Aiur.AgentRunner.{ReworkHandoffGuard, TurnCompletion}
  alias Aiur.LocalTestEvidence.Bullets

  @head String.duplicate("c", 40)
  @stale_head String.duplicate("a", 40)
  @base String.duplicate("d", 40)

  defp body(tested, bullet), do: "## Local tests\n\nPolicy: partial\nTested head: #{tested}\nBase: main @ #{@base}\nSelection: focused\n#{bullet}\n"

  test "normalize moves a note after the result and leaves other lines alone" do
    input = "- `mix test` unit only -> pass\n\n## Local tests\n\nPolicy: partial\n- `mix test` unit only -> 3 passed\n- `mix lint` -> ok\n\n## Other\n- `x` note -> y\n"

    assert Bullets.normalize(input) ==
             "- `mix test` unit only -> pass\n\n## Local tests\n\nPolicy: partial\n- `mix test` -> 3 passed (unit only)\n- `mix lint` -> ok\n\n## Other\n- `x` note -> y\n"
  end

  @tag :tmp_dir
  test "a staged body with a note between command and arrow is rewritten before it is applied", %{tmp_dir: tmp_dir} do
    raw = body(@head, "- `mix test` focused -> passed")
    fixed = body(@head, "- `mix test` -> passed (focused)")
    path = Path.join([tmp_dir, ".aiur-runtime", "tmp", "pr.md"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, raw)
    issue = %Aiur.Issue{id: "gid-7822", identifier: "7822", state: "in-progress"}
    test_pid = self()

    opts = [
      open_pr_fetcher: fn _ -> {:ok, %{"number" => 7900, "body" => body(@stale_head, "- `mix test` -> passed"), "head" => %{"sha" => @head}}} end,
      pull_request_body_updater: fn 7900, applied ->
        send(test_pid, {:applied, applied})
        {:ok, %{}}
      end,
      pull_request_refetcher: fn "7822" -> {:ok, %{"number" => 7900, "body" => fixed, "head" => %{"sha" => @head}}} end
    ]

    assert :allow = ReworkHandoffGuard.evidence_blockers(issue, "ci-wait", tmp_dir, opts)
    assert_receive {:applied, ^fixed}, 100
  end

  # A refused bound that kept the ticket active was redispatched within a minute
  # and looped no-op turns for hours, holding a slot; agent:error frees it.
  test "a no-op bound refused by the PR body check ends the ticket in error, not review or in-progress" do
    identifier = "7822-noop-#{System.unique_integer([:positive])}"
    use_memory_tracker!(self())
    issue = %Aiur.Issue{id: "gid-#{identifier}", identifier: identifier, state: "in-progress", labels: ["agent:in-progress"]}
    progress = %{consecutive_noops: 3}

    context = %{
      workspace: nil,
      worker_host: nil,
      turn_number: 3,
      opts: [open_pr_fetcher: fn _ -> {:ok, %{"number" => 7901, "body" => body(@stale_head, "- `mix test` -> passed"), "head" => %{"sha" => @head}}} end]
    }

    assert {:completed, %Aiur.Issue{state: "error"}} =
             TurnCompletion.complete_noop_bound_without_handoff(context, issue, progress, %{workspace: {:unavailable, :test}}, 3)

    assert_received {:memory_tracker_state_update, ^identifier, "error"}
    refute_received {:memory_tracker_state_update, ^identifier, "human-review"}
  end

  defp use_memory_tracker!(recipient) do
    write_workflow_file!(Aiur.Workflow.workflow_file_path(),
      tracker_kind: "memory",
      tracker_active_states: ["todo", "in-progress", "rework"]
    )

    Aiur.WorkflowStore.force_reload()
    Process.put(:memory_tracker_recipient, recipient)
  end
end
