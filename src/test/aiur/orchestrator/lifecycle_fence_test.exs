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

  test "a completed cached error does not restore over the first observed rework state" do
    issue_id = "issue-completed-error"
    identifier = "LF-3"

    state = %State{
      running: %{
        issue_id => %{
          identifier: identifier,
          completed_provenance: true,
          issue: %Issue{id: issue_id, identifier: identifier, state: "error"},
          control: %{status: :completed}
        }
      }
    }

    item = %Aiur.AgentQueueItem{id: 73, category: :operator_message, target_issue_identifier: identifier}
    fenced = LifecycleFence.protect_queued_item(state, identifier, item)

    observed = %Issue{id: issue_id, identifier: identifier, state: "rework"}
    assert {:fenced, reconciled} = LifecycleFence.reconcile_observed_state(fenced, observed)
    assert reconciled.running[issue_id].issue.state == "rework"
    assert reconciled.running[issue_id].lifecycle_fence.authoritative_state == "rework"
  end

  @approved_review_event %{
    id: 1,
    topic: "ticket.1577.pr.review_comment",
    issue_number: "1577",
    author_trusted?: true,
    comment: %{"id" => 1, "user" => %{"login" => "its-everdred"}, "state" => "APPROVED"},
    pull_request: %{"review_decision" => "APPROVED", "head_committed_at" => "2026-08-10T04:29:00Z"}
  }

  @changes_requested_review_event %{
    id: 2,
    topic: "ticket.1577.pr.review_comment",
    issue_number: "1577",
    author_trusted?: true,
    comment: %{"id" => 2, "user" => %{"login" => "its-everdred"}, "state" => "CHANGES_REQUESTED"},
    pull_request: %{"review_decision" => "CHANGES_REQUESTED", "head_committed_at" => "2026-08-10T04:29:00Z"}
  }

  # #1754: a trusted comment digest on an APPROVED PR must not arm the fence
  # with an authoritative "rework" state, or the fence restores a human-review
  # ticket to rework while `reviewDecision` is APPROVED (the no-op dispatch
  # loop). The CHANGES_REQUESTED pairing guards against an always-skip gate.
  test "an APPROVED PR comment digest does not arm the fence with rework" do
    state = running_entry_state()
    fenced = LifecycleFence.protect_queued_item(state, "1577", digest_item(1, [@approved_review_event]))
    entry = fenced.running["issue-approved-digest"]

    refute fence_authoritative_rework?(entry)

    observed = %Issue{id: "issue-approved-digest", identifier: "1577", state: "human-review"}
    assert :admit = LifecycleFence.reconcile_observed_state(fenced, observed)
  end

  test "a CHANGES_REQUESTED comment digest still arms the rework fence" do
    state = running_entry_state()
    fenced = LifecycleFence.protect_queued_item(state, "1577", digest_item(2, [@changes_requested_review_event]))
    entry = fenced.running["issue-approved-digest"]

    assert fence_authoritative_rework?(entry)

    observed = %Issue{id: "issue-approved-digest", identifier: "1577", state: "human-review"}
    assert {:fenced, reconciled} = LifecycleFence.reconcile_observed_state(fenced, observed)
    assert reconciled.running["issue-approved-digest"].issue.state == "rework"
  end

  defp running_entry_state do
    issue_id = "issue-approved-digest"

    %State{
      running: %{
        issue_id => %{
          identifier: "1577",
          issue: %Issue{id: issue_id, identifier: "1577", state: "in-progress"},
          control: %{status: :working}
        }
      }
    }
  end

  defp digest_item(id, events) do
    %Aiur.AgentQueueItem{
      id: id,
      category: :coordination_event,
      event_type: :events_digest,
      target_issue_identifier: "1577",
      body: %{summary: "PR review comment", events: events, urgent: false},
      source: :github_comments_poller
    }
  end

  defp fence_authoritative_rework?(entry) do
    case Map.get(entry, :lifecycle_fence) do
      %{authoritative_state: "rework"} -> true
      _other -> false
    end
  end
end
