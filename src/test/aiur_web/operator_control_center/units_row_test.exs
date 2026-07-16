defmodule AiurWeb.OperatorControlCenter.UnitsRowTest do
  use ExUnit.Case, async: true

  alias Aiur.TrackerIdentity
  alias AiurWeb.OperatorControlCenter.{UnitsPolicy, UnitsRow}

  test "joins all sources by repository-qualified identity, not a display identifier" do
    alpha = identity("acme", "alpha", "NODE-alpha", "7")
    beta = identity("acme", "beta", "NODE-beta", "7")

    snapshot =
      UnitsRow.snapshot(%{
        membership: membership([member(alpha), member(beta)], {:degraded, :journal_corrupt}),
        status: %{
          running: [status(alpha, title: "Status title", resolved_model: "gpt-5.6", workspace_path: "/private/workspace")],
          retrying: [],
          idle: []
        },
        activity: %{
          entries: [
            %{identity: alpha, progress: %{status: :known, percent: 40, source: :checkin, freshness: :stale}, latest_evidence: %{status: :known, source: :agent_event}}
          ]
        },
        decisions: %{entries: [%{identity: alpha, open_count: 2}, %{identity: beta, open_count: 1}]},
        issue_facts: %{
          entries: [
            facts(alpha, "Alpha canonical", "https://github.com/acme/alpha/issues/7"),
            facts(beta, "Beta canonical", "https://github.com/acme/beta/issues/7")
          ]
        }
      })

    assert snapshot.health.membership == :degraded
    assert {:ok, alpha_row} = UnitsRow.lookup(snapshot, alpha)
    assert {:ok, beta_row} = UnitsRow.lookup(snapshot, beta)

    assert alpha_row.title == "Alpha canonical"
    assert alpha_row.backend == :codex
    assert alpha_row.resolved_model == "gpt-5.6"
    assert alpha_row.field_sources.backend == :canonical_issue
    assert alpha_row.field_sources.resolved_model == :status_report
    assert alpha_row.open_command_count == 2
    assert alpha_row.progress == %{status: :known, percent: 40, source: :checkin, freshness: :stale}
    assert alpha_row.provider_health.membership == :degraded
    assert alpha_row.sources.membership.health == :degraded
    assert alpha_row.sources.status.available?
    assert alpha_row.url == "https://github.com/acme/alpha/issues/7"
    refute Map.has_key?(alpha_row, :workspace_path)
    refute Map.has_key?(alpha_row.runtime, :workspace_path)

    assert beta_row.title == "Beta canonical"
    assert beta_row.open_command_count == 1
    assert beta_row.progress == %{status: :unknown}
    refute beta_row.sources.status.available?
  end

  test "retains a terminal member when status and activity snapshots no longer contain it" do
    ticket = identity("acme", "alpha", "NODE-terminal", "8")

    snapshot =
      UnitsRow.snapshot(%{
        membership: membership([member(ticket, lifecycle: :completed, terminal?: true)]),
        status: %{running: [], retrying: [], idle: []},
        activity: %{entries: []},
        decisions: %{entries: []},
        issue_facts: %{entries: [facts(ticket, "Terminal ticket", "https://github.com/acme/alpha/issues/8")]}
      })

    assert {:ok, row} = UnitsRow.lookup(snapshot, ticket)
    assert row.terminal?
    assert row.lifecycle == :completed
    assert row.progress == %{status: :unknown}
    assert row.latest_evidence == %{status: :unknown}
    assert row.field_sources.open_command_count == :unknown
    refute row.sources.status.available?
  end

  test "keeps a completed awaiting-dispatch runtime row nonterminal and queued" do
    ticket = identity("acme", "alpha", "NODE-replacement", "9")

    snapshot =
      UnitsRow.snapshot(%{
        membership: membership([member(ticket)]),
        status: %{running: [status(ticket, work_state: :completed, waiting_reason: :awaiting_dispatch)], retrying: [], idle: []},
        activity: %{entries: []},
        decisions: %{entries: []},
        issue_facts: %{entries: [facts(ticket, "Replacement", "https://github.com/acme/alpha/issues/9")]}
      })

    assert {:ok, row} = UnitsRow.lookup(snapshot, ticket)
    assert row.replacement_boundary?
    refute row.terminal?
    assert row.lifecycle == :waiting
    assert row.runtime.bucket == :running
  end

  test "uses retry and pause facts without conflating their reasons" do
    retrying = identity("acme", "alpha", "NODE-retry", "12")
    paused = identity("acme", "alpha", "NODE-paused", "13")

    snapshot =
      UnitsRow.snapshot(%{
        membership: membership([member(retrying, lifecycle: :running), member(paused, lifecycle: :paused)]),
        status: %{
          running: [status(paused, tracker_paused: true, pause_reason: :executor)],
          retrying: [status(retrying, waiting_reason: :backing_off)],
          idle: []
        },
        issue_facts: %{
          entries: [
            facts(retrying, "Retrying", "https://github.com/acme/alpha/issues/12"),
            facts(paused, "Paused", "https://github.com/acme/alpha/issues/13")
          ]
        }
      })

    assert {:ok, retry_row} = UnitsRow.lookup(snapshot, retrying)
    assert retry_row.runtime.bucket == :retrying
    assert retry_row.reasons.waiting == :backing_off
    assert UnitsPolicy.in_scope?(retry_row, :unfinished)
    assert UnitsPolicy.condition?(:queued, retry_row)

    assert {:ok, paused_row} = UnitsRow.lookup(snapshot, paused)
    assert paused_row.reasons.pause == :executor
    assert UnitsPolicy.in_scope?(paused_row, :live)
    assert UnitsPolicy.condition?(:paused, paused_row)
  end

  test "normalizes trusted issue URLs once and rejects capability-shaped URLs" do
    ticket = identity("acme", "alpha", "NODE-url", "10")

    snapshot =
      UnitsRow.snapshot(%{
        membership: membership([member(ticket)]),
        status: %{running: [], retrying: [], idle: []},
        issue_facts: %{entries: [facts(ticket, "Unsafe URL", "https://github.com/acme/alpha/issues/10?token=private")]}
      })

    assert {:ok, row} = UnitsRow.lookup(snapshot, ticket)
    assert is_nil(row.url)
  end

  test "rejects an issue-shaped URL from an untrusted host" do
    ticket = identity("acme", "alpha", "NODE-host", "11")

    snapshot =
      UnitsRow.snapshot(%{
        membership: membership([member(ticket)]),
        status: %{running: [], retrying: [], idle: []},
        issue_facts: %{entries: [facts(ticket, "Untrusted host", "https://evil.example/acme/alpha/issues/11")]}
      })

    assert {:ok, row} = UnitsRow.lookup(snapshot, ticket)
    assert is_nil(row.url)
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

  defp membership(members, health \\ :healthy), do: %{generation: 4, health: health, freshness: %{status: :fresh}, members: members}

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
      url: Keyword.get(attrs, :url, "https://github.com/#{identity.owner}/#{identity.repository}/issues/#{identity.identifier}"),
      work_state: Keyword.get(attrs, :work_state, :working),
      waiting_reason: Keyword.get(attrs, :waiting_reason, :active),
      resolved_model: Keyword.get(attrs, :resolved_model),
      pause_reason: Keyword.get(attrs, :pause_reason),
      tracker_paused: Keyword.get(attrs, :tracker_paused, false),
      open_decision_count: Keyword.get(attrs, :open_decision_count, 0),
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
end
