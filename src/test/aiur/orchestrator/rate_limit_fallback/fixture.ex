defmodule Aiur.RateLimitFallbackFixture do
  @moduledoc false

  import ExUnit.Assertions
  import Aiur.TestSupport, only: [receive_barrier: 1]
  alias Aiur.Issue
  alias Aiur.Orchestrator.State

  @marker_label "agent:rate-limit-fallback"

  def fallback_state(labels, selected_backend \\ nil, status \\ :paused) do
    issue = %Issue{id: "1", identifier: "repo#1", labels: labels, selected_backend: selected_backend}

    entry =
      fallback_entry(%{
        identifier: issue.identifier,
        issue: issue,
        control: %{status: status},
        paused_reason: if(status == :paused, do: :usage_limit_exhausted, else: nil)
      })

    %State{running: %{issue.id => entry}}
  end

  def fallback_entry(overrides) do
    Map.merge(
      %{
        identifier: "repo#1",
        issue: %Issue{id: "1", identifier: "repo#1", labels: []},
        worker_host: "worker-2",
        control: %{status: :paused},
        paused_reason: :usage_limit_exhausted,
        started_at: DateTime.add(DateTime.utc_now(), -3_600, :second)
      },
      overrides
    )
  end

  def record_started_dispatch(state, issue) do
    entry = %{pid: self(), issue: issue, identifier: issue.identifier}

    %{
      state
      | completed: MapSet.put(state.completed, issue.id),
        running: Map.put(state.running, issue.id, entry)
    }
  end

  def recovered_state do
    %{
      "backends" => %{
        "codex" => %{
          "limited" => false,
          "available_observed_at" => DateTime.utc_now() |> DateTime.to_iso8601()
        }
      }
    }
  end

  def reconcile_opts(overrides \\ []) do
    Keyword.merge(
      [
        fallback_backend: "claude",
        primary_backend: "codex",
        marker_label: @marker_label,
        current_backend: "codex",
        state: recovered_state(),
        minimum_dwell_seconds: 0,
        backend_ready_fun: fn _backend, _worker_host -> true end,
        dispatch_ready_fun: fn _state, _issue, _worker_host -> :ok end
      ],
      overrides
    )
  end

  def assert_label_ops(expected) do
    actual =
      Enum.map(expected, fn _operation ->
        receive_barrier({:label_op, operation})
        operation
      end)

    assert actual == expected
  end
end
