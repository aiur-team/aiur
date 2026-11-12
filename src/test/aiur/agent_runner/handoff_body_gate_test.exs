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

  test "a no-op bound does not park a ticket in human-review past a failing PR body" do
    identifier = "7822-noop-#{System.unique_integer([:positive])}"
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    issue = %Aiur.Issue{id: "gid-#{identifier}", identifier: identifier, state: "in-progress", labels: ["agent:in-progress"]}
    progress = %{consecutive_noops: 3}

    context = %{
      workspace: nil,
      worker_host: nil,
      turn_number: 3,
      opts: [open_pr_fetcher: fn _ -> {:ok, %{"number" => 7901, "body" => body(@stale_head, "- `mix test` -> passed"), "head" => %{"sha" => @head}}} end]
    }

    assert {:completed, %Aiur.Issue{state: "in-progress"}} =
             TurnCompletion.complete_noop_bound_without_handoff(context, issue, progress, %{workspace: {:unavailable, :test}}, 3)

    refute_received {:memory_tracker_state_update, ^identifier, "human-review"}
  end

  # Open-Games #286/#302/#310: a refused body at the no-op bound crashed the run
  # (CaseClauseError), burned all three retries and released the claim.
  test "a no-op bound whose pushed-rework handoff is refused stops the run instead of crashing" do
    identifier = "7822-bound-#{System.unique_integer([:positive])}"
    Application.put_env(:aiur, :memory_tracker_recipient, self())
    issue = %Aiur.Issue{id: "gid-#{identifier}", identifier: identifier, state: "in-progress", labels: ["agent:in-progress"]}
    pr = %{"number" => 7902, "body" => body(@stale_head, "- `mix test` -> passed"), "head" => %{"sha" => @head}}

    context = %{
      workspace: nil,
      worker_host: nil,
      turn_number: 5,
      max_turns: 12,
      opts: [
        rework_head_sha: @stale_head,
        open_pr_fetcher: fn _ -> {:ok, pr} end,
        reviews_fetcher: fn 7902 -> {:ok, []} end,
        pull_request_approval_fetcher: fn 7902 -> {:error, :not_found} end,
        commit_ci_status_fetcher: fn @head -> {:ok, %{check_runs: [%{"status" => "queued"}], commit_status: %{}}} end
      ]
    }

    assert {:error, {:rework_handoff_evidence_refused, :stale_pr_body_evidence, _message}} = TurnCompletion.noop_handoff(context, issue)

    assert {:completed, %Aiur.Issue{state: "in-progress"}} =
             TurnCompletion.stop_on_noop_bound(context, issue, %{consecutive_noops: 3}, %{workspace: {:unavailable, :test}}, 3)

    refute_received {:memory_tracker_state_update, ^identifier, _state}
  end
end
