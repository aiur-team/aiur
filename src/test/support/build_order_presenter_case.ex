defmodule AiurWeb.BuildOrderPresenterCase do
  @moduledoc false

  alias Aiur.BuildOrder.{Dependency, Diagnostic, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrderViewModel

  @repository {"owner", "repo"}
  @now ~U[2026-07-15 12:00:00Z]

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: true

      import AiurWeb.BuildOrderPresenterCase

      alias Aiur.BuildOrder.{Dependency, Diagnostic, Member, ProviderHealth, RootSummary, SelectedRoot}
      alias Aiur.BuildOrder.GraphProjection.Snapshot
      alias Aiur.TrackerIdentity
      alias AiurWeb.BuildOrderPresenter
      alias AiurWeb.BuildOrderViewModel

      Module.put_attribute(__MODULE__, :repository, unquote(Macro.escape(@repository)))
      Module.put_attribute(__MODULE__, :now, unquote(Macro.escape(@now)))
    end
  end

  def snapshot(members, opts \\ []) do
    root_identity = identity(100)
    health = Keyword.get(opts, :health, ProviderHealth.new(7, :healthy, true, observed_at: @now))
    selected = SelectedRoot.new(root(root_identity), members, health)

    %Snapshot{
      scope: {:selected, root_identity},
      repository: @repository,
      generation: 7,
      data: selected,
      health: health
    }
  end

  def root(identity) do
    RootSummary.new(%{
      identity: identity,
      title: "Build Order",
      url: issue_url(identity.identifier),
      state: :open,
      state_reason: nil,
      labels: ["build-order"],
      updated_at: @now
    })
  end

  def member(number, opts \\ []) do
    labels = [
      "complexity:#{Keyword.get(opts, :complexity, 3)}",
      "phase:#{Keyword.get(opts, :phase, 1)}",
      "build-lane:#{Keyword.get(opts, :lane, "plan-graph")}"
    ]

    Member.new(%{
      identity: identity(number),
      title: "Ticket #{number}",
      url: issue_url(number),
      state: Keyword.get(opts, :state, :open),
      state_reason: Keyword.get(opts, :state_reason),
      labels: labels,
      updated_at: @now,
      dependencies: Keyword.get(opts, :dependencies, [])
    })
  end

  def target_with_blockers(target, blockers) do
    dependencies =
      Enum.map(blockers, fn blocker ->
        Dependency.new(identity(target), identity(blocker), issue_url(blocker), :blocked_by)
      end)

    member(target, dependencies: dependencies)
  end

  def status_snapshot, do: %{running: [], retrying: [], idle: []}
  def activity_snapshot(entries \\ []), do: %{generation: 12, entries: entries, diagnostics: %{}}

  def activity(identity, progress, stage) do
    %{
      identity: identity,
      status: :fresh,
      active_stage: stage,
      stage: %{status: :known, value: stage, freshness: :fresh, observed_at: @now, event_id: 2},
      progress: %{
        status: :known,
        percent: progress,
        source: :checkin,
        freshness: :fresh,
        occurred_at: @now,
        observed_at: @now,
        event_id: 3,
        body: "issue body"
      },
      latest_evidence: %{
        status: :known,
        source: %{kind: :agent_event, name: "progress.checkin"},
        attributes: %{percent: progress, body: "issue body"},
        provenance: %{run_id: "run-1", token: "secret"},
        occurred_at: @now,
        observed_at: @now,
        event_id: 3,
        body: "issue body"
      },
      provenance: %{run_id: "run-1", token: "secret"},
      observed_at: @now,
      retention: :current
    }
  end

  def node(%BuildOrderViewModel{} = model, number),
    do: Enum.find(model.nodes, &(&1.identity.identifier == to_string(number)))

  def diagnostic_codes(model), do: Enum.map(model.diagnostics, & &1.code)
  def key(number), do: TrackerIdentity.github_key(identity(number))

  def identity(number, provider_id \\ nil, repository \\ @repository) do
    {owner, name} = repository

    %TrackerIdentity{
      version: 1,
      status: :joinable,
      kind: :github,
      owner: owner,
      repository: name,
      provider_id: provider_id || "ISSUE-#{number}",
      identifier: to_string(number),
      reason: nil
    }
  end

  def issue_url(number), do: "https://github.com/owner/repo/issues/#{number}"
end
