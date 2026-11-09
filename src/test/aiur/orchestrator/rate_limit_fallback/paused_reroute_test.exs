Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.RateLimitFallback.PausedRerouteTest do
  use ExUnit.Case, async: true

  import Aiur.RateLimitFallbackFixture, only: [fallback_entry: 1, record_started_dispatch: 2]

  alias Aiur.Issue
  alias Aiur.Orchestrator.{RateLimitFallback, Slots, State}

  # Claude exhausted, then codex routed for this complexity: every limited
  # entry moves to codex in one tick, with no fallback labels to revert later.
  test "reroutes every paused claude entry onto the codex route in one tick without labels" do
    state = %State{max_concurrent_agents: 2, running: Map.new(["1", "2"], &{&1, limited_entry(&1)})}
    test_pid = self()

    result =
      RateLimitFallback.reconcile(
        state,
        opts(
          add_label_fun: fn _identifier, label -> send(test_pid, {:label, label}) && :ok end,
          dispatch_fun: fn current_state, issue, _attempt, _worker_host ->
            send(test_pid, {:dispatch, issue.id, issue.selected_backend})
            record_started_dispatch(current_state, issue)
          end
        )
      )

    assert_received {:dispatch, "1", "codex"}
    assert_received {:dispatch, "2", "codex"}
    refute_received {:label, _}
    assert result.running["2"].issue.selected_backend == "codex"
  end

  test "a ready limited entry that finds the fleet full gets the next slot before new work" do
    active = %{issue: %Issue{id: "active", identifier: "repo#9"}, control: %{status: :working}}
    state = %State{max_concurrent_agents: 1, running: %{"1" => limited_entry("1"), "active" => active}}

    result =
      RateLimitFallback.reconcile(
        state,
        opts(dispatch_ready_fun: fn _state, _issue, _host -> {:error, :no_available_slots} end)
      )

    assert result.running["1"].awaiting_fleet_slot == true

    # The active agent finishes: the freed slot is not handed to a new ticket…
    freed = %{result | running: Map.delete(result.running, "active")}
    refute Slots.dispatch_slots_available?(%Issue{id: "new", state: "todo"}, freed)
    # …while the waiting entry's own reroute still sees it.
    assert Slots.replacement_slot_available?(freed, "1")
  end

  test "the slot-wait mark clears once the entry no longer needs a slot" do
    entry = Map.put(limited_entry("1"), :awaiting_fleet_slot, true)
    state = %State{max_concurrent_agents: 3, running: %{"1" => entry}}

    result = RateLimitFallback.reconcile(state, opts(state: %{"backends" => %{"codex" => limited(), "claude" => limited()}}))

    refute Map.has_key?(result.running["1"], :awaiting_fleet_slot)
  end

  defp limited_entry(id) do
    fallback_entry(%{
      identifier: "repo##{id}",
      # The issue already resolves to the new route; only the session knows it ran on claude.
      issue: %Issue{id: id, identifier: "repo##{id}", labels: ["complexity:4"], selected_backend: "codex"},
      worker_host: nil,
      paused_at: DateTime.add(DateTime.utc_now(), -601, :second),
      session_execution: %{backend: "claude"}
    })
  end

  defp limited, do: %{"limited" => true, "reset_at" => DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), 7_200, :second))}

  defp opts(overrides) do
    Keyword.merge(
      [
        fallback_backend: "claude",
        primary_backend: "codex",
        marker_label: "agent:rate-limit-fallback",
        routing_backend: "codex",
        state: %{"backends" => %{"claude" => limited()}},
        backend_ready_fun: fn _backend, _worker_host -> true end,
        dispatch_ready_fun: fn state, _issue, _worker_host -> {:ok, state} end,
        teardown_fun: fn current_state, _entry, _reason -> current_state end,
        dispatch_fun: fn current_state, issue, _attempt, _worker_host -> record_started_dispatch(current_state, issue) end
      ],
      overrides
    )
  end
end
