Code.require_file("fixture.ex", __DIR__)

defmodule Aiur.Orchestrator.RateLimitFallback.RecoveryTest do
  use ExUnit.Case, async: true

  import Aiur.RateLimitFallbackFixture,
    only: [fallback_state: 2, fallback_state: 3, fallback_entry: 1, record_started_dispatch: 2, reconcile_opts: 1, assert_label_ops: 1]

  alias Aiur.Issue
  alias Aiur.Orchestrator.RateLimitFallback
  alias Aiur.Orchestrator.State

  @marker_label "agent:rate-limit-fallback"

  describe "reconcile/2" do
    test "reverts the fallback labels and redispatches to the original worker" do
      state = fallback_state(["model:claude", @marker_label], "claude")
      test_pid = self()

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            fallback_backend: "config-changed-after-engage",
            add_label_fun: fn identifier, label ->
              send(test_pid, {:label_op, {:add, identifier, label}})
              :ok
            end,
            remove_label_fun: fn identifier, label ->
              send(test_pid, {:label_op, {:remove, identifier, label}})
              :ok
            end,
            teardown_fun: fn current_state, running_entry, reason ->
              send(test_pid, {:teardown, running_entry.identifier, reason})
              current_state
            end,
            dispatch_fun: fn current_state, issue, attempt, worker_host ->
              send(test_pid, {:dispatch, issue, attempt, worker_host})
              record_started_dispatch(current_state, issue)
            end
          )
        )

      assert result.completed == MapSet.new(["1"])

      assert_label_ops([
        {:remove, "repo#1", "model:claude"},
        {:remove, "repo#1", @marker_label}
      ])

      assert_received {:teardown, "repo#1", :rate_limit_fallback}
      assert_received {:dispatch, %Issue{labels: [], selected_backend: "codex"}, nil, "worker-2"}
      refute_received {:label_op, _}
    end

    test "requests a safe checkpoint and waits for worker pause before reverting" do
      state = fallback_state(["model:claude", @marker_label], "claude", :working)
      test_pid = self()

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            pause_fun: fn _current_state, identifier ->
              send(test_pid, {:pause, identifier})
              {:ok, 7}
            end,
            add_label_fun: fn _, _ -> flunk("must not relabel a working fallback") end,
            remove_label_fun: fn _, _ -> flunk("must not relabel a working fallback") end,
            teardown_fun: fn _, _, _ -> flunk("must not tear down mid-turn") end,
            dispatch_fun: fn _, _, _, _ -> flunk("must not dispatch mid-turn") end
          )
        )

      assert_received {:pause, "repo#1"}
      assert get_in(result.running, ["1", :control, :status]) == :working
      assert get_in(result.running, ["1", :paused_reason]) == :rate_limit_fallback_recovery
      assert get_in(result.running, ["1", :rate_limit_fallback_revert_pending]) == true
    end

    test "cancels a pending recovery checkpoint when codex becomes limited again" do
      reset_at = DateTime.add(DateTime.utc_now(), 3_600, :second) |> DateTime.to_iso8601()
      state = fallback_state(["model:claude", @marker_label], "claude", :working)

      state =
        update_in(state.running["1"], fn entry ->
          entry
          |> Map.put(:rate_limit_fallback_revert_pending, true)
          |> Map.put(:paused_reason, :rate_limit_fallback_recovery)
        end)

      result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            state: %{
              "backends" => %{
                "codex" => %{"limited" => true, "reset_at" => reset_at}
              }
            },
            add_label_fun: fn _, _ -> flunk("must not mutate labels while cancelling") end,
            remove_label_fun: fn _, _ -> flunk("must not mutate labels while cancelling") end
          )
        )

      refute Map.has_key?(result.running["1"], :rate_limit_fallback_revert_pending)
      refute Map.has_key?(result.running["1"], :paused_reason)
    end

    test "revert removes only the fallback-owned model label" do
      state = fallback_state(["model:codex", "model:claude", @marker_label], "claude")
      test_pid = self()

      _result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            add_label_fun: fn _, _ -> :ok end,
            remove_label_fun: fn identifier, label ->
              send(test_pid, {:label_op, {:remove, identifier, label}})
              :ok
            end,
            teardown_fun: fn current_state, _, _ -> current_state end,
            dispatch_fun: fn current_state, issue, _, _ ->
              send(test_pid, {:redispatched_issue, issue})
              record_started_dispatch(current_state, issue)
            end
          )
        )

      assert_label_ops([
        {:remove, "repo#1", "model:claude"},
        {:remove, "repo#1", @marker_label}
      ])

      assert_received {:redispatched_issue, %Issue{labels: ["model:codex"], selected_backend: "codex"}}
    end

    test "revert honors an operator route added during fallback" do
      state =
        fallback_state(
          ["model:claude", @marker_label, "model:claude-opus"],
          "claude"
        )

      test_pid = self()

      _result =
        RateLimitFallback.reconcile(
          state,
          reconcile_opts(
            add_label_fun: fn _, _ -> :ok end,
            remove_label_fun: fn _, _ -> :ok end,
            teardown_fun: fn current_state, _, _ -> current_state end,
            dispatch_fun: fn current_state, issue, _, _ ->
              send(test_pid, {:redispatched_issue, issue})
              record_started_dispatch(current_state, issue)
            end
          )
        )

      assert_received {:redispatched_issue, %Issue{labels: ["model:claude-opus"], selected_backend: "claude"}}
    end

    test "hands the pause cause to resume so the pause attention can be resolved" do
      # PauseResume reads `:paused_reason` off the entry it is given to emit the
      # matching `agent.attention.paused-<cause>.resolved`. Cancelling a
      # deferred revert used to strip the reason first, so the resolution was
      # skipped and the pause attention stayed active forever.
      issue = %Issue{id: "1", identifier: "repo#1", labels: ["model:claude", @marker_label], selected_backend: "claude"}

      entry =
        fallback_entry(%{
          issue: issue,
          control: %{status: :paused},
          paused_reason: :rate_limit_fallback_recovery,
          rate_limit_fallback_revert_pending: true
        })

      test_pid = self()

      RateLimitFallback.reconcile(
        %State{running: %{issue.id => entry}},
        reconcile_opts(
          # Force the deferred-revert cancel path.
          dispatch_ready_fun: fn _state, _issue, _worker_host -> {:error, :max_concurrent_agents_reached} end,
          resume_fun: fn current_state, resumed_entry ->
            send(test_pid, {:resumed_with, Map.get(resumed_entry, :paused_reason)})
            {{:ok, :resumed}, current_state}
          end
        )
      )

      assert_received {:resumed_with, :rate_limit_fallback_recovery}
    end
  end
end
