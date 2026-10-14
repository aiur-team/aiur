defmodule AiurWeb.OperatorControlCenter.UnitsPresenterFixtures do
  @moduledoc false

  alias Aiur.TrackerIdentity

  def payload(identity) do
    %{
      generated_at: "2026-07-17T12:00:00Z",
      provider_health: %{fleet: :ok, decisions: :ok},
      fleet: %{
        running: [
          %{
            tracker_identity: identity,
            state: "in-progress",
            title: "Render Units",
            url: "https://github.com/its-everdred/aiur/issues/41",
            backend: "codex",
            agent_family: "codex",
            requested_model: "gpt-5.6",
            effort: "high",
            complexity: 3,
            labels: ["complexity:3", "build-lane:dashboard-ui"],
            work_state: :working,
            waiting_reason: :active,
            open_decision_count: 2,
            open_decision_count_health: :available,
            runtime_seconds: 90,
            workspace_path: "/private/agent/workspace"
          }
        ],
        retrying: [],
        idle: []
      },
      decisions: [
        %{
          lifecycle: :recorded,
          ticket: %{identifier: "41", url: "https://github.com/its-everdred/aiur/issues/41"}
        }
      ]
    }
  end

  def fleet_entry(identity, attrs \\ []) do
    %{
      identifier: identity.identifier,
      tracker_identity: identity,
      state: "in-progress",
      title: "Unit #{identity.identifier}",
      url: "https://github.com/#{identity.owner}/#{identity.repository}/issues/#{identity.identifier}",
      backend: "codex",
      agent_family: "codex",
      labels: [],
      work_state: Keyword.get(attrs, :work_state, :working),
      waiting_reason: Keyword.get(attrs, :waiting_reason, :active)
    }
  end

  def membership(members) do
    %{
      generation: 7,
      health: :healthy,
      health_message: "current-run membership is healthy",
      freshness: %{status: :fresh},
      members: members,
      truncated?: false
    }
  end

  def member(identity) do
    %{
      identity: identity,
      lifecycle: :running,
      terminal?: false,
      first_observed_at: ~U[2026-07-17 11:00:00Z],
      last_observed_at: ~U[2026-07-17 12:00:00Z]
    }
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
