defmodule Aiur.Orchestrator.LifecycleFenceTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{DispatchPolicy, LifecycleFence, State}

  test "a newer observed rework epoch supersedes a lesser active-state fence" do
    issue_id = "issue-fence-rework"
    identifier = "LF-1"

    state = %State{
      running: %{
        issue_id => %{
          identifier: identifier,
          issue: %Issue{
            id: issue_id,
            identifier: identifier,
            state: "in-progress"
          },
          control: %{status: :working},
          lifecycle_fence: %{
            authoritative_state: "in-progress",
            generation: 3,
            opened_at: DateTime.utc_now(),
            pending_item_ids: MapSet.new([41])
          }
        }
      }
    }

    observed = %Issue{
      id: issue_id,
      identifier: identifier,
      state: "rework"
    }

    assert {:fenced, next} = LifecycleFence.reconcile_observed_state(state, observed)
    assert next.running[issue_id].issue.state == "rework"

    assert %{
             authoritative_state: "rework",
             generation: 4,
             pending_item_ids: pending_item_ids
           } = next.running[issue_id].lifecycle_fence

    assert pending_item_ids == MapSet.new([41])
  end

  test "a terminal tracker state remains fenced during the grace window" do
    issue_id = "issue-fence-terminal"
    identifier = "LF-3"

    state = %State{
      running: %{
        issue_id => %{
          identifier: identifier,
          issue: %Issue{
            id: issue_id,
            identifier: identifier,
            state: "in-progress"
          },
          control: %{status: :working},
          lifecycle_fence: %{
            authoritative_state: "in-progress",
            generation: 1,
            opened_at: DateTime.utc_now(),
            pending_item_ids: MapSet.new([99])
          }
        }
      }
    }

    # Simulate the Executor closing the issue out-of-band (normal post-merge flow).
    # The fence is still active waiting for a queued item, but the tracker says closed.
    observed = %Issue{id: issue_id, identifier: identifier, state: "closed"}

    assert {:fenced, ^state} =
             LifecycleFence.reconcile_observed_state(state, observed, DispatchPolicy.terminal_state_set())
  end

  test "a terminal tracker state admits after the grace window" do
    issue_id = "issue-fence-terminal-both"
    identifier = "LF-4"

    state = %State{
      running: %{
        issue_id => %{
          identifier: identifier,
          issue: %Issue{id: issue_id, identifier: identifier, state: "closed"},
          control: %{status: :working},
          lifecycle_fence: %{
            authoritative_state: "in-progress",
            generation: 1,
            opened_at: DateTime.add(DateTime.utc_now(), -31, :second),
            pending_item_ids: MapSet.new([100])
          }
        }
      }
    }

    observed = %Issue{id: issue_id, identifier: identifier, state: "closed"}

    assert :admit =
             LifecycleFence.reconcile_observed_state(state, observed, DispatchPolicy.terminal_state_set())
  end

  test "a non-terminal diverging observed state remains fenced (restore_nonterminal path)" do
    issue_id = "issue-fence-nonterminal-diverge"
    identifier = "LF-6"

    state = %State{
      running: %{
        issue_id => %{
          identifier: identifier,
          issue: %Issue{id: issue_id, identifier: identifier, state: "in-progress"},
          control: %{status: :working},
          lifecycle_fence: %{
            authoritative_state: "in-progress",
            generation: 1,
            opened_at: DateTime.utc_now(),
            pending_item_ids: MapSet.new([102])
          }
        }
      }
    }

    # Observed state is non-terminal, non-matching, non-rework: should stay fenced.
    observed = %Issue{id: issue_id, identifier: identifier, state: "human-review"}

    assert {:fenced, _} = LifecycleFence.reconcile_observed_state(state, observed)
  end

  test "a matching handoff state remains fenced until provider delivery" do
    issue_id = "issue-matching-handoff"
    issue = %Issue{id: issue_id, identifier: "LF-2", state: "human-review"}

    state = %State{
      running: %{
        issue_id => %{
          identifier: issue.identifier,
          issue: issue,
          control: %{status: :working},
          lifecycle_fence: %{
            authoritative_state: "human-review",
            generation: 1,
            opened_at: DateTime.utc_now(),
            pending_item_ids: MapSet.new([42])
          }
        }
      }
    }

    assert {:fenced, ^state} = LifecycleFence.reconcile_observed_state(state, issue)
  end
end
