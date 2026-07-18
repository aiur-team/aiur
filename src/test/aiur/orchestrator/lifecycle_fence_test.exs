defmodule Aiur.Orchestrator.LifecycleFenceTest do
  use ExUnit.Case, async: true

  alias Aiur.Issue
  alias Aiur.Orchestrator.{LifecycleFence, State}

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
