defmodule Aiur.Projections.UnitsRowDecisionTest do
  use ExUnit.Case, async: true

  alias Aiur.Projections.UnitsRow
  alias Aiur.TrackerIdentity

  test "falls back to the status count when a Decision entry has no count" do
    ticket = identity("acme", "alpha", "NODE-missing-decision-count", "15")

    row =
      snapshot_row(ticket,
        status: status(ticket, open_decision_count: 2),
        decisions: %{entries: [%{identity: ticket}]}
      )

    assert row.open_command_count == 2
    assert row.field_sources.open_command_count == :status_report
    assert row.reasons.alert == :open_command
  end

  test "falls back to the status count after an invalid Decision count" do
    ticket = identity("acme", "alpha", "NODE-invalid-decision-count", "16")

    row =
      snapshot_row(ticket,
        status: status(ticket, open_decision_count: 2),
        decisions: %{entries: [%{identity: ticket, open_count: -1}]}
      )

    assert row.open_command_count == 2
    assert row.field_sources.open_command_count == :status_report
    assert row.reasons.alert == :open_command
  end

  test "a degraded zero Decision count cannot clear a positive status alert" do
    ticket = identity("acme", "alpha", "NODE-degraded-decision-count", "17")

    row =
      snapshot_row(ticket,
        status: status(ticket, open_decision_count: 2),
        decisions: %{
          health: {:degraded, :stale},
          entries: [%{identity: ticket, open_count: 0}]
        }
      )

    assert row.provider_health.decisions == :degraded
    assert row.open_command_count == 2
    assert row.field_sources.open_command_count == :status_report
    assert row.reasons.alert == :open_command
  end

  test "a valid positive Decision count wins a positive count conflict" do
    ticket = identity("acme", "alpha", "NODE-conflicting-decision-count", "18")

    row =
      snapshot_row(ticket,
        status: status(ticket, open_decision_count: 2),
        decisions: %{entries: [%{identity: ticket, open_count: 1}]}
      )

    assert row.open_command_count == 1
    assert row.field_sources.open_command_count == :decisions
    assert row.reasons.alert == :open_command
  end

  test "an unavailable Commands provider cannot turn a fallback zero into an exact fact" do
    ticket = identity("acme", "alpha", "NODE-unavailable-decision-count", "19")

    row =
      snapshot_row(ticket,
        status: status(ticket, open_decision_count: 0),
        decisions: %{health: {:unavailable, :store_restarting}, entries: []}
      )

    assert row.provider_health.decisions == :unavailable
    assert row.open_command_count == nil
    assert row.field_sources.open_command_count == :unknown
    assert row.reasons.alert == nil
  end

  test "an unavailable status count provider cannot turn its fallback zero into an exact fact" do
    ticket = identity("acme", "alpha", "NODE-unavailable-status-count", "21")

    row =
      snapshot_row(ticket,
        status:
          status(ticket,
            open_decision_count: 0,
            open_decision_count_health: :unavailable
          ),
        decisions: %{health: {:degraded, :bounded_overview}, entries: []}
      )

    assert row.provider_health.decisions == :degraded
    assert row.open_command_count == nil
    assert row.field_sources.open_command_count == :unknown
    assert row.reasons.alert == nil
  end

  test "an unavailable Commands provider preserves a positive fallback alert" do
    ticket = identity("acme", "alpha", "NODE-unavailable-positive-count", "20")

    row =
      snapshot_row(ticket,
        status: status(ticket, open_decision_count: 2),
        decisions: %{health: {:unavailable, :store_restarting}, entries: []}
      )

    assert row.open_command_count == 2
    assert row.field_sources.open_command_count == :status_report
    assert row.reasons.alert == :open_command
  end

  defp identity(owner, repository, provider_id, identifier) do
    %TrackerIdentity{
      status: :joinable,
      kind: :github,
      owner: owner,
      repository: repository,
      provider_id: provider_id,
      identifier: identifier,
      reason: nil
    }
  end

  defp membership(members, health \\ :healthy) do
    %{generation: 4, health: health, freshness: %{status: :fresh}, members: members}
  end

  defp member(identity, attrs \\ []) do
    %{
      identity: identity,
      lifecycle: Keyword.get(attrs, :lifecycle, :running),
      terminal?: Keyword.get(attrs, :terminal?, false),
      first_observed_at: ~U[2026-07-15 10:00:00Z],
      last_observed_at: ~U[2026-07-15 10:01:00Z]
    }
  end

  defp status(identity, attrs) do
    %{
      tracker_identity: identity,
      state: Keyword.get(attrs, :state, "in-progress"),
      title: Keyword.get(attrs, :title, "Status ticket"),
      url:
        Keyword.get(
          attrs,
          :url,
          "https://github.com/#{identity.owner}/#{identity.repository}/issues/#{identity.identifier}"
        ),
      work_state: Keyword.get(attrs, :work_state, :working),
      waiting_reason: Keyword.get(attrs, :waiting_reason, :active),
      resolved_model: Keyword.get(attrs, :resolved_model),
      turn_count: Keyword.get(attrs, :turn_count),
      turn_count_observed?: Keyword.has_key?(attrs, :turn_count),
      context_usage: Keyword.get(attrs, :context_usage),
      pause_reason: Keyword.get(attrs, :pause_reason),
      tracker_paused: Keyword.get(attrs, :tracker_paused, false),
      lifecycle: Keyword.get(attrs, :lifecycle),
      open_decision_count: Keyword.get(attrs, :open_decision_count, 0),
      open_decision_count_health: Keyword.get(attrs, :open_decision_count_health, :available),
      live_conversation: Keyword.get(attrs, :live_conversation),
      control: Keyword.get(attrs, :control, %{}),
      workspace_path: Keyword.get(attrs, :workspace_path),
      runtime_seconds: 15
    }
  end

  defp facts(identity, title, url) do
    %{
      tracker_identity: identity,
      title: title,
      url: url,
      state: "in-progress",
      selected_backend: :codex,
      agent_family: :codex,
      requested_model: "gpt-5",
      effort: "high",
      labels: ["complexity:3", "build-lane:dashboard-ui"]
    }
  end

  defp snapshot_row(ticket, opts) do
    snapshot =
      UnitsRow.snapshot(%{
        membership: membership([member(ticket)]),
        status: %{
          running: [Keyword.fetch!(opts, :status)],
          retrying: [],
          idle: []
        },
        activity: %{entries: []},
        decisions: Keyword.fetch!(opts, :decisions),
        issue_facts: %{
          entries: [facts(ticket, "Decision count", "https://github.com/acme/alpha/issues/#{ticket.identifier}")]
        }
      })

    assert {:ok, row} = UnitsRow.lookup(snapshot, ticket)
    row
  end
end
