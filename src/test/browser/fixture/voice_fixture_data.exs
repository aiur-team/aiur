defmodule Aiur.BrowserHarness.VoiceFixtureData do
  @moduledoc false
  alias Aiur.TrackerIdentity
  @now ~U[2026-07-17 12:00:00Z]

  def primary_row do
    row(identity("NODE-1110", "1110"), %{
      title: "Responsive Units interface",
      live_conversation: %{generation_handle: "conversation:" <> String.duplicate("a", 43), state: :live, health: :healthy, freshness: :current}
    })
  end

  def conversation_snapshot(reply \\ :without_reply) do
    messages =
      [
        %{
          id: "fixture-message",
          role: "agent",
          title: "Assistant",
          body: "Conversation drawer hook is running.",
          occurred_at: @now,
          observed_at: @now
        }
      ] ++ conversation_reply(reply)

    %{
      state: :live,
      health: :healthy,
      freshness: :current,
      messages: messages,
      observed_at: @now,
      truncated?: false,
      evicted_count: 0,
      source: %{worker_generation: 1, session_id: "fixture-session"}
    }
  end

  def conversation_reply(:without_reply), do: []

  def conversation_reply(:with_partial_reply) do
    [
      %{
        id: "fixture-voice-reply",
        role: "agent",
        title: "Assistant",
        body: "Voice reply",
        complete?: false,
        occurred_at: @now,
        observed_at: @now
      }
    ]
  end

  def conversation_reply(:with_reply) do
    [
      %{
        id: "fixture-voice-reply",
        role: "agent",
        title: "Assistant",
        body: "Voice reply from the agent.",
        complete?: true,
        occurred_at: @now,
        observed_at: @now
      }
    ]
  end

  def row(identity, overrides) do
    Map.merge(
      %{
        identity: identity,
        title: "Unit #{identity.identifier}",
        url: "https://github.com/its-everdred/aiur/issues/#{identity.identifier}",
        lifecycle: :active,
        terminal?: false,
        replacement_boundary?: false,
        tracker_state: "in-progress",
        backend: :codex,
        agent_family: :codex,
        requested_model: "gpt-5.6-terra",
        resolved_model: nil,
        effort: :high,
        account: nil,
        complexity: 3,
        build_lane: "L2",
        reasons: reasons(:active, nil, nil, nil, nil),
        runtime: runtime(:running, :working, :active, 60),
        timestamps: %{started_at: "2026-07-17T11:00:00Z"},
        open_command_count: 0,
        progress: %{status: :unknown},
        latest_evidence: %{status: :unknown},
        provider_health: %{
          membership: :available,
          status: :available,
          activity: :available,
          decisions: :available,
          issue: :available
        },
        field_sources: %{},
        sources: %{}
      },
      overrides
    )
  end

  def runtime(bucket, work_state, waiting_reason, seconds) do
    %{
      bucket: bucket,
      work_state: work_state,
      waiting_reason: waiting_reason,
      tracker_paused?: work_state == :paused,
      runtime_seconds: seconds,
      stale_for_seconds: 0,
      membership_lifecycle: :active
    }
  end

  def reasons(waiting, blocking, alert, pause, stuck) do
    %{waiting: waiting, blocking: blocking, alert: alert, pause: pause, stuck: stuck}
  end

  def identity(provider_id, identifier) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: "its-everdred",
      repository: "aiur",
      provider_id: provider_id,
      identifier: identifier,
      reason: nil
    }
  end
end
