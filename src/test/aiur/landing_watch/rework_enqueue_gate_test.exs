defmodule Aiur.LandingWatch.ReworkEnqueueGateTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.LandingWatch
  alias Aiur.Orchestrator.{StartupClaimReconciler.Observation, State}

  @green %{"id" => 60, "name" => "ci gate", "status" => "completed", "conclusion" => "success", "check_suite" => %{"id" => 101}}

  test "approved PR dequeued while its ticket is in rework with a running agent is not re-enqueued" do
    parent = self()

    for state <- ["rework", "in-progress", "todo"] do
      assert :ok =
               LandingWatch.process(
                 approved_observation("old-head"),
                 landing_opts(parent, state, journal_path())
               )
    end

    refute_received {:enqueued, _head}
  end

  test "approved PR is enqueued once its head changed and the ticket returned to ci-wait" do
    parent = self()

    path = journal_path()

    assert :ok = LandingWatch.process(approved_observation("old-head"), landing_opts(parent, "rework", path))
    assert :ok = LandingWatch.process(approved_observation("new-head"), landing_opts(parent, "ci-wait", path))

    refute_received {:enqueued, "old-head"}
    assert_received {:enqueued, "new-head"}
  end

  test "a gating label wins over a review label whichever order GitHub lists them" do
    parent = self()

    for labels <- [["agent:human-review", "agent:rework"], ["agent:rework", "agent:human-review"]] do
      request_fun = fn %{url: url} ->
        assert url =~ "/issues/17"
        {:ok, %{status: 200, body: %{"labels" => Enum.map(labels, &%{"name" => &1})}, headers: []}}
      end

      opts =
        parent
        |> landing_opts(nil, journal_path())
        |> Keyword.delete(:ticket_state_fun)
        |> Keyword.merge(repository: {"owner", "gate-#{System.unique_integer([:positive])}"}, token: "t", request_fun: request_fun)

      assert :ok = LandingWatch.process(approved_observation("old-head"), opts)
    end

    refute_received {:enqueued, _head}
  end

  test "a parked approved green PR stays out of the merge queue and alerts once across polls" do
    parent = self()
    path = journal_path()
    opts = landing_opts(parent, "ci-wait", path) |> Keyword.put(:ticket_state_fun, fn "17", _ -> {:ok, %{state: "ci-wait", paused?: false, held?: true}} end)
    observation = approved_observation("held-head")

    assert :ok = LandingWatch.process(observation, opts)
    assert :ok = LandingWatch.process(observation, opts)

    refute_received {:enqueued, _head}
    assert_received {:alert, "ticket.17.agent.attention.approved_pr_not_armed_for_merge"}
    refute_received {:alert, "ticket.17.agent.attention.approved_pr_not_armed_for_merge"}
  end

  test "approved green unarmed ci-wait candidates remain undispatched across polls" do
    issue = %Issue{id: "5615", identifier: "5615", title: "held PR", state: "ci-wait"}
    projection = %{decision: :passed, review_decision: "APPROVED", head_sha: "current-head", auto_merge_request: nil, merge_queue_entry: nil}
    ci_lifecycle = %State{}.ci_lifecycle
    state = %State{ci_lifecycle: %{ci_lifecycle | poll_cache: %{issue.identifier => projection}}}

    for _poll <- 1..4 do
      assert [] = Observation.dispatch_candidates(state, [issue])
    end
  end

  defp landing_opts(parent, ticket_state, path) do
    [
      approved_fun: fn _, _ -> {:ok, true} end,
      required_checks_fun: fn _ -> {:ok, [%{name: "ci gate", app_id: nil}]} end,
      ci_status_fun: fn _, _ -> {:ok, %{check_runs: [@green], commit_status: %{"state" => "success", "statuses" => []}}} end,
      revalidate_fun: fn 17, _, _ -> :ok end,
      attribution_fun: fn _ -> {:ok, :clean} end,
      ticket_state_fun: fn "17", _ -> {:ok, ticket_state} end,
      alert_emitter: fn topic, _details ->
        send(parent, {:alert, topic})
        :ok
      end,
      enqueue_fun: fn pr ->
        send(parent, {:enqueued, pr.head})
        {:ok, "entry-1"}
      end,
      journal_path: path
    ]
  end

  # Dequeued by the Executor: no merge queue entry and auto-merge disabled.
  defp approved_observation(head) do
    %{
      number: 17,
      node_id: "PR_node",
      head: head,
      draft?: false,
      review_decision: "APPROVED",
      merge_queue_entry: nil,
      auto_merge_request: nil,
      rest: %{"head" => %{"ref" => "aiur/17-work"}},
      raw: %{"reviewDecision" => "APPROVED", "headRefOid" => head, "isDraft" => false, "reviews" => %{"nodes" => [%{"commit" => %{"oid" => head}}]}}
    }
  end

  defp journal_path do
    path = Path.join(System.tmp_dir!(), "landing-watch-#{System.unique_integer([:positive])}.json")
    ExUnit.Callbacks.on_exit(fn -> Aiur.TestCleanup.rm_rf!(path) end)
    path
  end
end
