defmodule Aiur.Orchestrator.IssueSync.ClosedIssueCleanupTest do
  use Aiur.TestSupport

  alias Aiur.Issue
  alias Aiur.Orchestrator.IssueSync
  alias Aiur.Orchestrator.IssueSync.ClosedIssueCleanup
  alias Aiur.Orchestrator.State

  defmodule ClosedIssueTracker do
    def issue_closure("7388", 0), do: {:ok, %{open?: false, state_reason: "completed"}}

    def update_issue_state("7388", target, opts) do
      clear = Keyword.fetch!(opts, :clear_terminal_state_labels)
      current = ["agent:rework", "agent:ci-wait", "agent:human-review"]
      remaining = Enum.uniq(["agent:#{target}" | Enum.reject(current, &(&1 in clear))])
      send(Process.get({__MODULE__, :test_pid}), {:labels_after_close, remaining})
      :ok
    end
  end

  test "issue synchronization cleans lifecycle labels for an ordinary closed ticket" do
    original_adapters = Application.fetch_env!(:aiur, :tracker_adapters)
    Application.put_env(:aiur, :tracker_adapters, Map.put(original_adapters, "github", ClosedIssueTracker))

    on_exit(fn -> Application.put_env(:aiur, :tracker_adapters, original_adapters) end)
    Process.put({ClosedIssueTracker, :test_pid}, self())
    write_workflow_file!(Aiur.Workflow.workflow_file_path(), tracker_kind: "github", tracker_repo: "owner/repo")

    previous_issue = %Issue{
      id: "7388",
      identifier: "7388",
      state: "rework",
      state_labels: ["rework", "ci-wait", "human-review"],
      labels: ["agent:rework", "agent:ci-wait", "agent:human-review"]
    }

    closed_issue = %Issue{
      id: "7388",
      identifier: "7388",
      state: "Closed",
      state_labels: ["rework", "ci-wait", "human-review"],
      labels: ["agent:rework", "agent:ci-wait", "agent:human-review"]
    }

    IssueSync.sync_polled_issue_state(
      %State{last_polled_issues: %{"7388" => previous_issue}},
      [],
      fn ["7388"] -> {:ok, [closed_issue]} end,
      fn _identity, _lifecycle -> :ok end,
      MapSet.new(["done", "cancelled"]),
      fn _identity -> :ok end,
      fn _identity, _pending? -> :ok end
    )

    assert_receive {:labels_after_close, ["agent:done"]}, 1_000

    running_state = %State{
      last_polled_issues: %{"7388" => previous_issue},
      running: %{"7388" => %{identifier: "7388"}}
    }

    IssueSync.sync_polled_issue_state(
      running_state,
      [],
      fn ["7388"] -> {:ok, [closed_issue]} end,
      fn _identity, _lifecycle -> :ok end,
      MapSet.new(["done", "cancelled"]),
      fn _identity -> :ok end,
      fn _identity, _pending? -> :ok end
    )

    assert_receive {:labels_after_close, ["agent:done"]}, 1_000
  end

  test "closed issue poll clears stale lifecycle labels and retains only its terminal label" do
    issue = %Issue{
      id: "7386",
      identifier: "7386",
      state: "Closed",
      state_labels: ["rework", "ci-wait", "human-review"],
      labels: ["agent:rework", "agent:ci-wait", "agent:human-review"]
    }

    assert :ok =
             ClosedIssueCleanup.cleanup(issue,
               label_prefix: "agent",
               issue_closure_fun: fn "7386" -> {:ok, %{open?: false, state_reason: "completed"}} end,
               update_state_fun: &apply_terminal_labels/3
             )

    assert_receive {:labels_after_close, ["agent:done"]}, 1_000
  end

  test "not planned closure maps stale state labels to cancelled" do
    issue = %Issue{
      id: "7387",
      identifier: "7387",
      state: "closed",
      state_labels: ["rework"],
      labels: ["agent:rework"]
    }

    assert :ok =
             ClosedIssueCleanup.cleanup(issue,
               label_prefix: "agent",
               issue_closure_fun: fn "7387" -> {:ok, %{open?: false, state_reason: "not_planned"}} end,
               update_state_fun: &apply_terminal_labels/3
             )

    assert_receive {:labels_after_close, ["agent:cancelled"]}, 1_000
  end

  defp apply_terminal_labels(_identifier, target, opts) do
    clear = Keyword.fetch!(opts, :clear_terminal_state_labels)
    current = ["agent:rework", "agent:ci-wait", "agent:human-review"]
    remaining = Enum.uniq(["agent:#{target}" | Enum.reject(current, &(&1 in clear))])
    send(self(), {:labels_after_close, remaining})
    :ok
  end
end
