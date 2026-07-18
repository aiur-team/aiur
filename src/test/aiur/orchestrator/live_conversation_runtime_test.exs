defmodule Aiur.Orchestrator.LiveConversationRuntimeTest do
  use ExUnit.Case, async: false

  alias Aiur.{AgentPubSub, Issue, TrackerIdentity}
  alias Aiur.LiveConversation.Source
  alias Aiur.Orchestrator.State

  test "fences runtime status by worker, exact source, epoch, revision, and restart" do
    issue = issue()
    issue_id = issue.id
    :ok = AgentPubSub.subscribe_running()

    state = %State{
      running: %{
        issue_id => %{
          identifier: issue.identifier,
          issue: issue,
          control: %{generation: 7, status: :working},
          started_at: ~U[2026-07-17 12:00:00Z]
        }
      },
      last_polled_issues: %{issue_id => issue}
    }

    first = status(7, "session-a", epoch("A"), 1, 1)
    assert {:noreply, state} = State.handle_worker_runtime_info(state, issue_id, %{live_conversation: first})
    assert state.running[issue_id].live_conversation == first
    assert_receive {:running_changed, _summaries}

    assert {:noreply, ^state} =
             State.handle_worker_runtime_info(state, issue_id, %{live_conversation: first})

    refute_receive {:running_changed, _summaries}, 100

    wrong_worker = status(8, "session-a", epoch("A"), 2, 1)

    assert {:noreply, ^state} =
             State.handle_worker_runtime_info(state, issue_id, %{live_conversation: wrong_worker})

    next_session = status(7, "session-b", epoch("A"), 3, 2)

    assert {:noreply, rotated} =
             State.handle_worker_runtime_info(state, issue_id, %{
               live_conversation: next_session
             })

    assert rotated.running[issue_id].live_conversation.source.session_id ==
             Source.opaque_session_id("session-b")

    assert_receive {:running_changed, _summaries}

    late_predecessor = status(7, "session-a", epoch("A"), 4, 1)

    assert {:noreply, ^rotated} =
             State.handle_worker_runtime_info(rotated, issue_id, %{
               live_conversation: late_predecessor
             })

    wrong_epoch = status(7, "session-b", epoch("B"), 5, 2)

    assert {:noreply, ^rotated} =
             State.handle_worker_runtime_info(rotated, issue_id, %{
               live_conversation: wrong_epoch
             })

    restarted_at = ~U[2026-07-17 12:01:00Z]

    assert {:noreply, restarted} =
             State.handle_live_conversation_restart(rotated, epoch("B"), restarted_at)

    assert %{
             state: :restart_unknown,
             projection_epoch: projection_epoch,
             revision: 0,
             source: nil
           } = restarted.running[issue_id].live_conversation

    assert projection_epoch == epoch("B")
    assert_receive {:running_changed, _summaries}

    same_worker_after_restart = status(7, "session-b", epoch("B"), 1, 1)

    assert {:noreply, ^restarted} =
             State.handle_worker_runtime_info(restarted, issue_id, %{
               live_conversation: same_worker_after_restart
             })

    refute_receive {:running_changed, _summaries}, 100

    replacement_entry =
      restarted.running[issue_id]
      |> Map.put(:control, %{generation: 8, status: :working})
      |> Map.delete(:live_conversation)
      |> Map.delete(:live_conversation_fence)

    replacement_state = put_in(restarted.running[issue_id], replacement_entry)
    replacement = status(8, "replacement-session", epoch("B"), 2, 2)

    assert {:noreply, accepted} =
             State.handle_worker_runtime_info(replacement_state, issue_id, %{
               live_conversation: replacement
             })

    assert accepted.running[issue_id].live_conversation == replacement
    assert_receive {:running_changed, _summaries}
  end

  defp status(worker_generation, session_id, projection_epoch, revision, source_revision) do
    %{
      projection_epoch: projection_epoch,
      revision: revision,
      source_revision: source_revision,
      generation_handle: "conversation:" <> String.duplicate("C", 43),
      source: %{
        identity: %{
          version: 1,
          kind: :github,
          owner: "owner",
          repository: "repo",
          identifier: "1130"
        },
        run_id: "run-1",
        attempt_id: "attempt-1",
        session_id: Source.opaque_session_id(session_id),
        backend: "codex",
        worker_generation: worker_generation
      },
      state: :live,
      health: :healthy,
      freshness: :current,
      observed_at: DateTime.add(~U[2026-07-17 12:00:00Z], revision, :second)
    }
  end

  defp epoch(character), do: "projection:" <> String.duplicate(character, 43)

  defp issue do
    identity = %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "owner",
      repository: "repo",
      provider_id: "provider-1130",
      identifier: "1130",
      reason: nil
    }

    %Issue{
      id: "gid-1130-runtime",
      identifier: "1130",
      title: "runtime fence",
      state: "in-progress",
      tracker_identity: identity
    }
  end
end
