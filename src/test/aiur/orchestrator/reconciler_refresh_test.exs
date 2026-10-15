defmodule Aiur.Orchestrator.ReconcilerRefreshTest do
  use Aiur.TestSupport

  alias Aiur.{Alerts, Config, Issue}
  alias Aiur.Events.{Exchange, Publisher}
  alias Aiur.Orchestrator.{Reconciler, State}
  alias Aiur.Workspace.Layout

  describe "refresh_running_issue_states/3" do
    test "reuses visible candidates and fetches only missing running IDs" do
      old_one = %Issue{id: "one", identifier: "I-one", state: "Todo", title: "One"}
      old_two = %Issue{id: "two", identifier: "I-two", state: "In Progress", title: "Two"}
      fresh_one = %{old_one | state: "todo"}
      fresh_two = %{old_two | state: "Todo"}

      state = %State{
        running: %{
          "one" => %{identifier: "I-one", issue: old_one, control: %{status: :working}},
          "two" => %{identifier: "I-two", issue: old_two, control: %{status: :working}}
        }
      }

      fetch_fun = fn ids ->
        send(self(), {:fetched_running_ids, ids})
        {:ok, [fresh_two]}
      end

      next = Reconciler.refresh_running_issue_states(state, [fresh_one], fetch_fun)

      assert_receive {:fetched_running_ids, ["two"]}, 1000
      assert next.running["one"].issue.state == "todo"
      assert next.running["two"].issue.state == "Todo"
    end

    test "skips fallback reads when every running issue is visible" do
      issue = %Issue{id: "one", identifier: "I-one", state: "todo", title: "One"}

      state = %State{
        running: %{
          "one" => %{identifier: "I-one", issue: %{issue | state: "Todo"}, control: %{status: :working}}
        }
      }

      next =
        Reconciler.refresh_running_issue_states(state, [issue], fn _ids ->
          flunk("visible running issues must not be fetched twice")
        end)

      assert next.running["one"].issue.state == "todo"
    end

    test "keeps missing workers when the fallback tracker read fails" do
      issue = %Issue{id: "missing", identifier: "I-missing", state: "in-progress", title: "Missing"}

      state = %State{
        running: %{
          "missing" => %{identifier: "I-missing", issue: issue, control: %{status: :working}}
        }
      }

      assert Reconciler.refresh_running_issue_states(state, [], fn ["missing"] -> {:error, :tracker_down} end) ==
               state
    end
  end

  describe "reconcile_running_issue_states/4" do
    test "returns state unchanged for empty list" do
      state = %State{running: %{"issue-1" => %{pid: self()}}}
      active = MapSet.new(["todo"])
      terminal = MapSet.new(["done"])

      assert Reconciler.reconcile_running_issue_states([], state, active, terminal) == state
    end

    test "emits an attention alert when the local label override disagrees with the tracker" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.I-divergence.agent.attention.state_divergence")
      :ok = Exchange.subscribe("ticket.I-divergence.agent.attention.state_divergence.resolved")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      issue = %Issue{id: "issue-divergence", identifier: "I-divergence", state: "in-progress", paused: false}

      state = %State{
        running: %{
          "issue-divergence" => %{
            identifier: "I-divergence",
            issue: issue,
            control: %{status: :paused},
            paused_reason: :label_override
          }
        }
      }

      state = Reconciler.report_label_divergence(state, issue)

      assert_receive {:event, %{topic: "ticket.I-divergence.agent.attention.state_divergence"} = event}, 500
      assert event["reason"] =~ "local=paused(label_override) tracker=agent:in-progress"

      assert Reconciler.report_label_divergence(state, issue) == state
      refute_receive {:event, %{topic: "ticket.I-divergence.agent.attention.state_divergence"}}, 100

      recovered_issue = %{issue | paused: true}
      recovered = Reconciler.report_label_divergence(state, recovered_issue)

      assert_receive {:event, %{topic: "ticket.I-divergence.agent.attention.state_divergence.resolved"} = event},
                     500

      assert event["reason"] =~ "Resolved: State reconciliation detected divergence"
      refute Map.has_key?(recovered.running[issue.id], :label_divergence_reported)

      rearmed = Reconciler.report_label_divergence(recovered, issue)

      assert_receive {:event, %{topic: "ticket.I-divergence.agent.attention.state_divergence"}}, 500
      assert get_in(rearmed.running, [issue.id, :label_divergence_reported]) =~ "local=paused"
    end

    test "reports a tracker pause while the local worker remains active" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.I-paused.agent.attention.state_divergence")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      issue = %Issue{id: "issue-paused", identifier: "I-paused", state: "in-progress", paused: true}

      state = %State{
        running: %{
          issue.id => %{identifier: issue.identifier, issue: issue, control: %{status: :working}}
        }
      }

      _state = Reconciler.report_label_divergence(state, issue)

      assert_receive {:event, %{topic: "ticket.I-paused.agent.attention.state_divergence"} = event}, 500
      assert event["reason"] =~ "local=working tracker=agent:paused"
    end

    test "reports a duration pause while the tracker remains active" do
      Publisher.set_tracked_fn(fn _ -> true end)
      :ok = Exchange.subscribe("ticket.I-duration.agent.attention.state_divergence")

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      issue = %Issue{id: "issue-duration", identifier: "I-duration", state: "rework", paused: false}

      state = %State{
        running: %{
          issue.id => %{
            identifier: issue.identifier,
            issue: issue,
            control: %{status: :paused},
            paused_reason: :max_agent_duration
          }
        }
      }

      _state = Reconciler.report_label_divergence(state, issue)

      assert_receive {:event, %{topic: "ticket.I-duration.agent.attention.state_divergence"} = event}, 500
      assert event["reason"] =~ "local=paused(max_agent_duration) tracker=agent:rework"
      assert event["reason"] =~ "operator resume is required"
    end

    test "resolves and rearms a persisted divergence after restart" do
      Publisher.set_tracked_fn(fn _ -> true end)
      topic = "ticket.I-restart-divergence.agent.attention.state_divergence"
      resolved_topic = "#{topic}.resolved"
      :ok = Exchange.subscribe(topic)
      :ok = Exchange.subscribe(resolved_topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      assert :ok =
               Alerts.emit_custom(topic, "Persisted divergence",
                 issue: "I-restart-divergence",
                 reason: "Persisted divergence",
                 needs_attention: true,
                 severity: "warning"
               )

      assert_receive {:event, %{topic: ^topic}}, 500

      issue = %Issue{id: "issue-restart-divergence", identifier: "I-restart-divergence", state: "rework"}

      recovered = %State{active_attention_topics: MapSet.new([topic])}

      rearmed = Reconciler.report_label_divergence(recovered, issue)

      assert_receive {:event, %{topic: ^resolved_topic}}, 500
      refute Map.has_key?(rearmed.running, issue.id)

      paused = %{issue | paused: true}
      running = %{identifier: issue.identifier, issue: paused, control: %{status: :working}}

      rearmed = %{
        rearmed
        | running: %{issue.id => running},
          active_attention_topics: MapSet.new()
      }

      _ = Reconciler.report_label_divergence(rearmed, paused)

      assert_receive {:event, %{topic: ^topic}}, 500
    end
  end

  describe "conditional running-issue refresh" do
    test "drops cache entries for issues that stopped running" do
      state = %State{}
      assert Reconciler.refresh_running_issue_states(state) === state

      stale = %{state | running_issue_cache: %{"stale" => %{etag: "old"}}}
      assert Reconciler.refresh_running_issue_states(stale).running_issue_cache == %{}
    end

    test "retains the stable per-issue cache between reconciliation cycles" do
      issue = %Issue{id: "issue-1", identifier: "repo#1", title: "current", state: "todo"}
      parent = self()

      issue_fetcher = fn issue_ids, cache ->
        send(parent, {:running_issue_fetch, issue_ids, cache})

        case cache do
          %{} when map_size(cache) == 0 ->
            {:ok, [issue], %{issue.id => %{etag: ~s("issue-1-v1"), issue: issue}}}

          %{"issue-1" => %{issue: cached_issue}} ->
            {:ok, [cached_issue], cache}
        end
      end

      state = %State{
        running: %{issue.id => %{pid: self(), identifier: issue.identifier, issue: issue}}
      }

      first = Reconciler.refresh_running_issue_states(state, [], issue_fetcher)
      second = Reconciler.refresh_running_issue_states(first, [], issue_fetcher)

      assert_received {:running_issue_fetch, ["issue-1"], %{}}

      assert_received {:running_issue_fetch, ["issue-1"],
                       %{
                         "issue-1" => %{etag: ~s("issue-1-v1"), issue: ^issue}
                       }}

      assert second.running_issue_cache == first.running_issue_cache
      assert second.running[issue.id].issue == issue
    end

    test "keeps partial cache progress when a later issue request fails" do
      issue = %Issue{id: "issue-1", identifier: "repo#1", title: "current", state: "todo"}
      updated_cache = %{issue.id => %{etag: ~s("issue-1-v2"), issue: issue}}

      state = %State{
        running: %{issue.id => %{pid: self(), identifier: issue.identifier, issue: issue}},
        running_issue_cache: %{issue.id => %{etag: ~s("issue-1-v1"), issue: issue}}
      }

      issue_fetcher = fn ["issue-1"], _cache -> {:error, :tracker_down, updated_cache} end
      next = Reconciler.refresh_running_issue_states(state, [], issue_fetcher)

      assert next.running == state.running
      assert next.running_issue_cache == updated_cache
    end

    # The point of the merge: reuse and revalidation compose. A running ticket
    # present in the polled snapshot costs no request at all, and only the
    # remainder reaches the conditional fetcher.
    test "conditionally fetches only the running issues absent from the poll" do
      polled = %Issue{id: "issue-1", identifier: "repo#1", title: "polled", state: "todo"}
      missing = %Issue{id: "issue-2", identifier: "repo#2", title: "missing", state: "todo"}
      parent = self()

      issue_fetcher = fn issue_ids, cache ->
        send(parent, {:running_issue_fetch, issue_ids, cache})
        {:ok, [missing], Map.put(cache, missing.id, %{etag: ~s("issue-2-v1"), issue: missing})}
      end

      state = %State{
        running: %{
          polled.id => %{pid: self(), identifier: polled.identifier, issue: polled},
          missing.id => %{pid: self(), identifier: missing.identifier, issue: missing}
        }
      }

      next = Reconciler.refresh_running_issue_states(state, [polled], issue_fetcher)

      assert_received {:running_issue_fetch, ["issue-2"], %{}}
      refute_received {:running_issue_fetch, ["issue-1" | _], _}
      assert Map.keys(next.running_issue_cache) == ["issue-2"]
    end

    test "still accepts a cache-free arity-1 fetch fun" do
      issue = %Issue{id: "issue-1", identifier: "repo#1", title: "current", state: "todo"}

      state = %State{
        running: %{issue.id => %{pid: self(), identifier: issue.identifier, issue: issue}}
      }

      next = Reconciler.refresh_running_issue_states(state, [], fn ["issue-1"] -> {:ok, [issue]} end)

      assert next.running_issue_cache == %{}
      assert next.running[issue.id].issue == issue
    end
  end

  describe "refresh_running_issue_state/2" do
    test "updates the stored issue in the running entry" do
      old_issue = %Issue{id: "issue-1", identifier: "repo#1", title: "old", state: "todo"}
      new_issue = %Issue{id: "issue-1", identifier: "repo#1", title: "new", state: "in-progress"}

      state = %State{
        running: %{"issue-1" => %{pid: self(), issue: old_issue}}
      }

      result = Reconciler.refresh_running_issue_state(state, new_issue)
      assert get_in(result.running, ["issue-1", :issue]) == new_issue
    end

    test "returns state unchanged when issue_id is not running" do
      issue = %Issue{id: "issue-x", identifier: "repo#x", title: "t", state: "todo"}
      state = %State{running: %{}}

      assert Reconciler.refresh_running_issue_state(state, issue) == state
    end
  end

  describe "reconcile_missing_running_issue_ids/3" do
    test "resolves a persisted divergence when no running entry reconstructs" do
      Publisher.set_tracked_fn(fn _ -> true end)
      topic = "ticket.I-orphaned-divergence.agent.attention.state_divergence"
      resolved_topic = "#{topic}.resolved"
      workspace = Layout.issue_workspace_path(Config.workspace_root(), "I-orphaned-divergence")
      File.mkdir_p!(workspace)
      :ok = Exchange.subscribe(resolved_topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      assert :ok =
               Alerts.emit_custom(topic, "Persisted divergence",
                 issue: "I-orphaned-divergence",
                 workspace: workspace,
                 reason: "Persisted divergence",
                 needs_attention: true,
                 severity: "warning",
                 central: true
               )

      state = %State{active_attention_topics: MapSet.new([topic])}
      assert %State{} = Reconciler.resolve_orphaned_divergence_attentions(state)
      assert_receive {:event, %{topic: ^resolved_topic}}, 500
    end

    test "resolves a divergence before removing an absent running ticket" do
      Publisher.set_tracked_fn(fn _ -> true end)
      topic = "ticket.I-missing-divergence.agent.attention.state_divergence"
      resolved_topic = "#{topic}.resolved"
      :ok = Exchange.subscribe(topic)
      :ok = Exchange.subscribe(resolved_topic)

      on_exit(fn ->
        Publisher.set_tracked_fn(fn _ -> true end)
        for pattern <- Exchange.bindings_for(self()), do: Exchange.unsubscribe(pattern)
      end)

      issue = %Issue{id: "issue-missing-divergence", identifier: "I-missing-divergence", state: "rework"}

      state = %State{
        running: %{
          issue.id => %{
            pid: nil,
            ref: make_ref(),
            identifier: issue.identifier,
            issue: issue,
            started_at: DateTime.utc_now(),
            control: paused_control(),
            paused_reason: :max_agent_duration
          }
        }
      }

      opened = Reconciler.report_label_divergence(state, issue)
      assert_receive {:event, %{topic: ^topic}}, 500

      removed = Reconciler.reconcile_missing_running_issue_ids(opened, [issue.id], [])

      assert_receive {:event, %{topic: ^resolved_topic}}, 500
      refute Map.has_key?(removed.running, issue.id)
    end

    test "returns state unchanged when all requested ids are visible" do
      issue = %Issue{id: "issue-1", identifier: "repo#1", title: "t", state: "todo"}

      state = %State{
        running: %{"issue-1" => %{pid: self(), identifier: "repo#1"}},
        claimed: MapSet.new(["issue-1"])
      }

      assert Reconciler.reconcile_missing_running_issue_ids(state, ["issue-1"], [issue]) == state
    end

    test "returns state unchanged for non-State first arg" do
      assert Reconciler.reconcile_missing_running_issue_ids(:not_state, [], []) == :not_state
    end

    test "ignores non-Issue entries in the issues list" do
      state = %State{
        running: %{"issue-1" => %{pid: self(), identifier: "repo#1"}},
        claimed: MapSet.new(["issue-1"])
      }

      issue = %Issue{id: "issue-1", identifier: "repo#1", title: "t", state: "todo"}
      issues = [issue, :bad_entry, nil]

      assert Reconciler.reconcile_missing_running_issue_ids(state, ["issue-1"], issues) == state
    end
  end

  defp paused_control do
    %{
      status: :paused,
      can_interrupt: true,
      application_confirmation: :confirmed,
      generation: 1,
      version: 0
    }
  end
end
