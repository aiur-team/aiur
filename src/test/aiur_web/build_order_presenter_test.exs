defmodule AiurWeb.BuildOrderPresenterTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.{Dependency, Diagnostic, Member, ProviderHealth, RootSummary, SelectedRoot}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrderPresenter
  alias AiurWeb.BuildOrderViewModel

  @repository {"owner", "repo"}
  @now ~U[2026-07-15 12:00:00Z]

  test "joins exact planning, execution, and activity facts without collapsing them" do
    completed = member(1, state: :closed, state_reason: :completed, phase: 1)

    active =
      member(2,
        phase: 2,
        dependencies: [Dependency.new(identity(2), identity(1), issue_url(1), :blocked_by)]
      )

    blocked =
      member(3,
        lane: "runtime",
        dependencies: [Dependency.new(identity(3), identity(2), issue_url(2), :blocked_by)]
      )

    planning = snapshot([blocked, active, completed])

    execution = %{
      running: [
        %{
          tracker_identity: identity(2),
          work_state: :working,
          waiting_reason: :active,
          tracker_paused: false,
          runtime_seconds: 90,
          agent_input_tokens: 10,
          agent_output_tokens: 20,
          agent_total_tokens: 30,
          ci_result: %{decision: :pending, pr_number: 99, head_sha: "abc123"},
          last_codex_timestamp: @now
        }
      ],
      retrying: [],
      idle: []
    }

    activity = activity_snapshot([activity(identity(2), 42, :work)])

    model =
      BuildOrderPresenter.present(planning, execution, activity,
        selected_identity: identity(2),
        capabilities: %{issue: %{available?: true, url: issue_url(2), identity: identity(2), label: "Issue"}}
      )

    assert %BuildOrderViewModel{status: :ready, execution_health: :available, activity_health: :available} = model
    assert model.summary.members == 3
    assert model.summary.edges == 2
    assert model.summary.readiness == %{blocking: 1, ready: 2}
    assert model.adjacency[key(1)] == [key(2)]
    assert model.reverse_adjacency[key(3)] == [key(2)]

    active_node = node(model, 2)
    assert active_node.plan.lifecycle.state == :open
    assert active_node.readiness == :ready
    assert active_node.execution.work_state == :working
    refute Map.has_key?(active_node.execution, :tokens)
    assert active_node.execution.runtime_seconds == 90
    assert active_node.execution.ci_result.decision == :pending
    assert active_node.activity.progress.percent == 42
    assert active_node.activity.active_stage == :work
    assert active_node.card.progress == 42
    assert active_node.status_icon.key == :status_working

    assert active_node.provenance == %{
             planning_generation: 7,
             activity_generation: 12,
             activity: %{run_id: "run-1"}
           }

    assert model.relationships.status == :selected
    assert Enum.map(model.relationships.blocked_by, & &1.state) == [:cleared]
    assert Enum.map(model.relationships.blocking, & &1.state) == [:blocking]
    assert model.relationships.capabilities.issue.destination == issue_url(2)
    assert model.relationships.capabilities.chat.available? == false
    assert model.relationships.diagnostics == []

    refute inspect(model) =~ "issue body"
    refute Map.has_key?(active_node.card, :body)
    refute Map.has_key?(active_node.card, :description)
  end

  test "classifies all edge states and applies readiness precedence" do
    ready = member(1, state: :closed, state_reason: :completed)
    blocking = member(2)
    terminal = member(3, state: :closed, state_reason: :not_planned)
    unknown = member(4, state: :closed, state_reason: :duplicate)

    target =
      member(5,
        dependencies: [
          Dependency.new(identity(5), identity(1), issue_url(1), :blocked_by),
          Dependency.new(identity(5), identity(2), issue_url(2), :blocked_by),
          Dependency.new(identity(5), identity(3), issue_url(3), :blocked_by),
          Dependency.new(identity(5), identity(4), issue_url(4), :blocked_by)
        ]
      )

    model =
      BuildOrderPresenter.present(
        snapshot([target, unknown, terminal, blocking, ready]),
        status_snapshot(),
        activity_snapshot()
      )

    states = Map.new(model.edges, &{&1.source.identifier, &1.state})

    assert states == %{"1" => :cleared, "2" => :blocking, "3" => :terminal_unsatisfied, "4" => :unknown}
    assert node(model, 5).readiness == :unknown

    without_unknown = snapshot([target_with_blockers(5, [1, 2, 3]), terminal, blocking, ready])

    assert without_unknown |> BuildOrderPresenter.present(status_snapshot(), activity_snapshot()) |> node(5) |> Map.fetch!(:readiness) ==
             :terminal_unsatisfied

    only_blocking = snapshot([target_with_blockers(5, [1, 2]), blocking, ready])

    assert only_blocking |> BuildOrderPresenter.present(status_snapshot(), activity_snapshot()) |> node(5) |> Map.fetch!(:readiness) ==
             :blocking
  end

  test "cycles win over lifecycle and stay scoped to the exact SCC" do
    one = member(1, dependencies: [Dependency.new(identity(1), identity(2), issue_url(2), :blocked_by)])
    two = member(2, dependencies: [Dependency.new(identity(2), identity(1), issue_url(1), :blocked_by)])
    three = member(3, dependencies: [Dependency.new(identity(3), identity(2), issue_url(2), :blocked_by)])
    self = member(4, dependencies: [Dependency.new(identity(4), identity(4), issue_url(4), :blocked_by)])

    model = BuildOrderPresenter.present(snapshot([three, self, two, one]), status_snapshot(), activity_snapshot())

    assert Enum.map(model.edges, &{{&1.source.identifier, &1.target.identifier}, &1.state}) == [
             {{"1", "2"}, :cyclic},
             {{"2", "1"}, :cyclic},
             {{"2", "3"}, :blocking},
             {{"4", "4"}, :cyclic}
           ]

    assert node(model, 1).readiness == :cyclic
    assert node(model, 2).readiness == :cyclic
    assert node(model, 3).readiness == :blocking
    assert node(model, 4).readiness == :cyclic
  end

  test "keeps external and missing endpoints explicit, nonjoinable, and safe" do
    foreign = identity(9, "FOREIGN-9", {"other", "repo"})

    target =
      member(1,
        dependencies: [
          Dependency.new(identity(1), foreign, "https://github.com/other/repo/issues/9", :blocked_by),
          Dependency.new(identity(1), identity(8), issue_url(8), :blocked_by),
          Dependency.new(identity(1), nil, "https://github.com/owner/repo/issues/7", :blocked_by)
        ]
      )

    model = BuildOrderPresenter.present(snapshot([target]), status_snapshot(), activity_snapshot())

    assert Enum.map(model.edges, & &1.kind) == [:external, :native, :unknown]
    assert Enum.all?(model.edges, &(&1.state == :unknown))
    assert node(model, 1).readiness == :unknown
    assert :external_dependency in diagnostic_codes(model)
    assert :unresolved_internal_dependency in diagnostic_codes(model)
    assert model.adjacency[key(1)] == []

    external = Enum.find(model.edges, &(&1.kind == :external))
    assert external.url == "https://github.com/other/repo/issues/9"

    relationships = BuildOrderPresenter.relationships(model, identity(1))
    assert relationships.external == Enum.filter(relationships.blocked_by, &(&1.kind != :native))
  end

  test "same issue number in another repository never joins runtime facts" do
    ticket = member(42)
    foreign_same_number = identity(42, "FOREIGN", {"other", "repo"})

    execution = %{
      running: [%{tracker_identity: foreign_same_number, work_state: :working}],
      retrying: [],
      idle: []
    }

    activity = activity_snapshot([activity(foreign_same_number, 99, :review)])
    model = BuildOrderPresenter.present(snapshot([ticket]), execution, activity)

    assert node(model, 42).execution.status == :unknown
    assert node(model, 42).activity.status == :unknown
    assert node(model, 42).card.progress == :unknown
  end

  test "duplicate exact runtime identities fail only that subrecord closed" do
    ticket = member(1)
    execution_row = %{tracker_identity: identity(1), work_state: :working}
    activity_row = activity(identity(1), 70, :review)

    model =
      BuildOrderPresenter.present(
        snapshot([ticket]),
        %{running: [execution_row], retrying: [execution_row], idle: []},
        activity_snapshot([activity_row, activity_row])
      )

    assert node(model, 1).plan.lifecycle.state == :open
    assert node(model, 1).execution.status == :unknown
    assert node(model, 1).activity.status == :unknown
    assert node(model, 1).health.execution == :ambiguous
    assert node(model, 1).health.activity == :ambiguous
    assert :duplicate_identity in diagnostic_codes(model)
  end

  test "preserves metadata warnings and deterministic fallback groups" do
    ungrouped = Member.new(%{identity: identity(1), title: "Ungrouped", url: issue_url(1), state: :open, state_reason: nil})
    grouped = member(2, lane: "runtime", phase: 3)

    first = BuildOrderPresenter.present(snapshot([grouped, ungrouped]), status_snapshot(), activity_snapshot())
    second = BuildOrderPresenter.present(snapshot([ungrouped, grouped]), status_snapshot(), activity_snapshot())

    assert first == second
    assert Enum.map(first.lane_groups, &{&1.key, &1.label}) == [{"runtime", "Runtime"}, {:unassigned, "Unassigned"}]
    assert Enum.map(first.phase_groups, &{&1.key, &1.label}) == [{3, "Wave 3"}, {:unphased, "Unphased"}]
    assert :missing_lane in Enum.map(node(first, 1).diagnostics, & &1.code)
    assert :missing_phase in Enum.map(node(first, 1).diagnostics, & &1.code)
  end

  test "bounded view models stay deterministic and body-free at supported sizes" do
    for count <- [0, 1, 20, 50, 100] do
      members = if count == 0, do: [], else: Enum.map(1..count, &member/1)
      shuffled = Enum.reverse(members)

      first = BuildOrderPresenter.present(snapshot(members), status_snapshot(), activity_snapshot())
      second = BuildOrderPresenter.present(snapshot(shuffled), status_snapshot(), activity_snapshot())

      assert first == second
      assert length(first.nodes) == count
      assert first.status == if(count == 0, do: :empty, else: :ready)
      assert Enum.all?(first.nodes, &(Map.keys(&1.card) |> Enum.all?(fn key -> key not in [:body, :description] end)))
    end
  end

  test "icon precedence covers terminal, runtime, readiness, and generic fallbacks" do
    terminal = member(1, state: :closed, state_reason: :completed, lane: "not-a-lane")
    paused = member(2)
    waiting = member(3)
    retrying = member(4)

    execution = %{
      running: [
        %{tracker_identity: identity(1), work_state: :working},
        %{tracker_identity: identity(2), work_state: :working, tracker_paused: true},
        %{tracker_identity: identity(3), work_state: :working, waiting_reason: :ci}
      ],
      retrying: [%{tracker_identity: identity(4)}],
      idle: []
    }

    model = BuildOrderPresenter.present(snapshot([retrying, waiting, paused, terminal]), execution, activity_snapshot())

    assert node(model, 1).status_icon.key == :status_completed
    assert node(model, 1).lane_icon.key == :lane_generic
    assert node(model, 2).status_icon.key == :status_paused
    assert node(model, 3).status_icon.key == :status_waiting
    assert node(model, 4).status_icon.key == :status_retrying
  end

  test "an active waiting reason remains working rather than waiting" do
    execution = %{
      running: [%{tracker_identity: identity(1), work_state: :working, waiting_reason: :active}],
      retrying: [],
      idle: []
    }

    model = BuildOrderPresenter.present(snapshot([member(1)]), execution, activity_snapshot())
    assert node(model, 1).status_icon.key == :status_working
  end

  test "reports stale activity, missing activity, and unavailable sources independently" do
    stale = activity(identity(1), 90, :review) |> Map.put(:status, :stale)

    model =
      BuildOrderPresenter.present(
        snapshot([member(2), member(1)]),
        :unavailable,
        activity_snapshot([stale])
      )

    assert model.execution_health == :unavailable
    assert node(model, 1).activity.status == :stale
    assert node(model, 1).activity.progress.percent == 90
    assert node(model, 1).card.progress == :unknown
    assert node(model, 1).card.agent_stage == :unknown
    assert node(model, 2).activity.status == :unknown
    assert node(model, 1).execution.status == :unknown
    assert node(model, 1).health.execution == :unavailable
  end

  test "field-level stale activity does not project current-looking card facts" do
    stale_fields =
      activity(identity(1), 90, :review)
      |> put_in([:progress, :freshness], :stale)
      |> put_in([:stage, :freshness], :stale)

    model =
      BuildOrderPresenter.present(
        snapshot([member(1)]),
        status_snapshot(),
        activity_snapshot([stale_fields])
      )

    assert node(model, 1).activity.status == :fresh
    assert node(model, 1).activity.progress.freshness == :stale
    assert node(model, 1).activity.stage.freshness == :stale
    assert node(model, 1).card.progress == :unknown
    assert node(model, 1).card.agent_stage == :unknown
  end

  test "distinguishes empty, stale LKG, unavailable, and structural-invalid graphs" do
    assert BuildOrderPresenter.present(snapshot([]), status_snapshot(), activity_snapshot()).status == :empty

    stale_health = ProviderHealth.new(7, :stale, false, observed_at: @now)
    stale = snapshot([member(1)], health: stale_health)
    assert BuildOrderPresenter.present(stale, status_snapshot(), activity_snapshot()).status == :provider_stale
    assert BuildOrderPresenter.present(stale, status_snapshot(), activity_snapshot()) |> node(1) |> Map.fetch!(:readiness) == :ready

    unavailable = %Snapshot{
      scope: {:selected, identity(100)},
      repository: @repository,
      generation: :unknown,
      data: nil,
      health: %ProviderHealth{}
    }

    assert %{status: :provider_unavailable, nodes: []} =
             BuildOrderPresenter.present(unavailable, status_snapshot(), activity_snapshot())

    invalid_member = Member.new(%{title: "Missing identity", url: issue_url(8)})
    invalid = snapshot([invalid_member])
    assert BuildOrderPresenter.present(invalid, status_snapshot(), activity_snapshot()).status == :structurally_invalid
  end

  test "scope or repository mismatches fail the planning view closed" do
    valid = snapshot([member(1)])

    for malformed <- [
          %{valid | scope: {:selected, identity(101)}},
          %{valid | repository: {"other", "repo"}}
        ] do
      model = BuildOrderPresenter.present(malformed, status_snapshot(), activity_snapshot())
      assert model.status == :structurally_invalid
      assert node(model, 1).readiness == :ready
      assert :invalid_root in diagnostic_codes(model)
    end
  end

  test "capabilities accept only identity-qualified destination-specific routes" do
    model = BuildOrderPresenter.present(snapshot([member(1)]), status_snapshot(), activity_snapshot())

    relationships =
      BuildOrderPresenter.relationships(model, identity(1), %{
        issue: %{available?: true, url: "https://token@github.com/owner/repo/issues/1", identity: identity(1)},
        pull_request: %{available?: true, url: "https://github.com/owner/repo/pull/2", identity: identity(1), number: 2},
        commands: %{available?: true, path: "/decisions/1", identity: identity(1)},
        chat: %{available?: true, path: "/chat\nheader: value", identity: identity(1)}
      })

    refute relationships.capabilities.issue.available?
    assert relationships.capabilities.pull_request.destination == "https://github.com/owner/repo/pull/2"
    assert relationships.capabilities.commands.destination == "/decisions/1"
    refute relationships.capabilities.chat.available?
    assert BuildOrderPresenter.relationships(model, %{identifier: "1"}).status == :invalid_selection

    for unsafe <- [
          "/\\evil.example/path",
          "/\nevil.example/path",
          "/\tevil.example/path",
          <<"/", 255>>,
          "/" <> String.duplicate("a", 2_048)
        ] do
      relationships =
        BuildOrderPresenter.relationships(model, identity(1), %{
          chat: %{available?: true, path: unsafe, identity: identity(1)}
        })

      refute relationships.capabilities.chat.available?
      assert relationships.capabilities.chat.reason == :invalid_destination
    end

    for {kind, destination} <- [
          {:chat, "/chat/1?capability=private"},
          {:chat, "/chat/1#token=private"},
          {:chat, "/decisions/1"},
          {:commands, "/decisions/1?token=private"},
          {:commands, "/decisions/1#capability=private"},
          {:commands, "/chat/1"}
        ] do
      capability = %{available?: true, path: destination, identity: identity(1), active?: true, readable?: true}
      relationships = BuildOrderPresenter.relationships(model, identity(1), %{kind => capability})

      refute relationships.capabilities[kind].available?
      assert relationships.capabilities[kind].reason == :invalid_destination
      assert relationships.capabilities[kind].destination == nil
    end
  end

  test "capabilities retain only exact identity, readability, activity, and controlled reason facts" do
    model = BuildOrderPresenter.present(snapshot([member(1)]), status_snapshot(), activity_snapshot())

    relationships =
      BuildOrderPresenter.relationships(model, identity(1), %{
        issue: %{available?: true, url: issue_url(1), identity: identity(1)},
        pull_request: %{available?: true, url: "https://github.com/owner/repo/pull/8", identity: identity(1), number: 8},
        chat: %{available?: true, path: "/chat/1", identity: identity(1), active?: true, readable?: true},
        commands: %{available?: false, identity: identity(1), readable?: false, reason: :unauthorized}
      })

    assert relationships.capabilities.issue.identity == identity(1)
    assert relationships.capabilities.pull_request.number == 8
    assert relationships.capabilities.chat.active?
    assert relationships.capabilities.chat.readable?
    assert relationships.capabilities.commands.identity == identity(1)
    assert relationships.capabilities.commands.reason == :unauthorized

    unsafe_identity = %{identity(1) | provider_id: ""}
    normalized = BuildOrderPresenter.relationships(model, identity(1), %{chat: %{available?: true, path: "/chat/1", identity: unsafe_identity}})
    assert normalized.capabilities.chat.identity == nil

    arbitrary = BuildOrderPresenter.relationships(model, identity(1), %{commands: %{reason: :raw_provider_failure}})
    assert arbitrary.capabilities.commands.reason == :unavailable
  end

  test "redacts credential-shaped provenance and deduplicates opposite connection views" do
    token = "ghp_" <> String.duplicate("a", 36)
    one = member(1, dependencies: [Dependency.new(identity(1), identity(2), issue_url(2), :blocked_by)])
    two = member(2, dependencies: [Dependency.new(identity(2), identity(1), issue_url(1), :blocking)])
    observed = activity(identity(1), 10, :plan) |> Map.put(:provenance, %{run_id: token})

    model = BuildOrderPresenter.present(snapshot([one, two]), status_snapshot(), activity_snapshot([observed]))

    assert length(model.edges) == 1
    assert node(model, 1).activity.provenance == %{}
    refute inspect(model) =~ token
  end

  test "reports the concrete cold-read fault instead of a generic provider outage" do
    # The shape the projection stores after a failed read of a perfectly
    # well-formed Build Order: no data, and a provider that could not fetch.
    health =
      ProviderHealth.new(:unknown, :unavailable, false,
        failure: :invalid_planning_authority,
        last_success_at: @now
      )

    model =
      BuildOrderPresenter.present(
        %Snapshot{scope: {:selected, identity(100)}, repository: @repository, generation: :unknown, data: nil, health: health},
        status_snapshot(),
        activity_snapshot()
      )

    assert model.status == :provider_unavailable
    assert diagnostic_codes(model) == [:invalid_planning_authority]

    # Zeros must never stand in for unknown: the counts were never resolved.
    refute model.summary.resolved?
  end

  test "reports a fetched-but-degraded selected root as unavailable rather than structurally invalid" do
    degraded = %{SelectedRoot.new(root(identity(100)), [], ProviderHealth.new(:unknown, :unavailable, false)) | diagnostics: [Diagnostic.new(:call_budget_exhausted)]}

    snapshot = %Snapshot{
      scope: {:selected, identity(100)},
      repository: @repository,
      generation: 7,
      data: degraded,
      health: ProviderHealth.new(:unknown, :unavailable, false)
    }

    model = BuildOrderPresenter.present(snapshot, status_snapshot(), activity_snapshot())

    assert model.status == :provider_unavailable
  end

  test "still reports a genuinely malformed graph as structurally invalid" do
    malformed = Member.new(%{identity: identity(2), title: "Member", url: issue_url(2), dependencies: [:malformed]})

    model = BuildOrderPresenter.present(snapshot([malformed]), status_snapshot(), activity_snapshot())

    assert model.status == :structurally_invalid
    assert model.summary.resolved?
  end

  defp snapshot(members, opts \\ []) do
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

  defp root(identity) do
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

  defp member(number, opts \\ []) do
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

  defp target_with_blockers(target, blockers) do
    dependencies =
      Enum.map(blockers, fn blocker ->
        Dependency.new(identity(target), identity(blocker), issue_url(blocker), :blocked_by)
      end)

    member(target, dependencies: dependencies)
  end

  defp status_snapshot, do: %{running: [], retrying: [], idle: []}
  defp activity_snapshot(entries \\ []), do: %{generation: 12, entries: entries, diagnostics: %{}}

  defp activity(identity, progress, stage) do
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

  defp node(%BuildOrderViewModel{} = model, number),
    do: Enum.find(model.nodes, &(&1.identity.identifier == to_string(number)))

  defp diagnostic_codes(model), do: Enum.map(model.diagnostics, & &1.code)
  defp key(number), do: TrackerIdentity.github_key(identity(number))

  defp identity(number, provider_id \\ nil, repository \\ @repository) do
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

  defp issue_url(number), do: "https://github.com/owner/repo/issues/#{number}"
end
