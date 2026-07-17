defmodule AiurWeb.BuildOrder.TicketContextAdapterTest do
  use ExUnit.Case, async: true

  alias Aiur.BuildOrder.Diagnostic
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextAdapter
  alias AiurWeb.BuildOrder.TicketContextAdapter.Relationship
  alias AiurWeb.BuildOrder.TicketContextPresenter.View, as: BaseView
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}

  test "composes both relationship directions without rewriting edge or readiness truth" do
    selected = node(2, :terminal_unsatisfied, diagnostics: [Diagnostic.new(:missing_lane)])
    upstream = Enum.map(1..5, &node(&1 + 10, readiness_for(&1)))
    downstream = node(30, :blocking)

    states = [:cleared, :blocking, :terminal_unsatisfied, :unknown, :cyclic]

    blocked_by =
      Enum.zip_with(upstream, states, fn source, state ->
        edge(source, selected, state, "blocked-by-#{source.identity.identifier}")
      end)

    blocking = edge(selected, downstream, :blocking, "blocking-30")
    graph = model([selected, downstream | upstream], blocked_by ++ [blocking])
    base = base_view(selected.identity)

    view = TicketContextAdapter.present(graph, selected.identity, base, capabilities(selected.identity))

    assert view.status == :available
    assert view.reason == nil
    assert view.selected == selected
    assert view.base.identity == selected.identity
    assert view.base.detail.state == :stale
    assert view.base.history.state == :restart_unknown
    assert view.base.logs.entries == []

    assert Enum.map(view.blocked_by, & &1.edge.state) == states
    assert Enum.all?(view.blocked_by, &match?(%Relationship{direction: :blocked_by}, &1))
    assert Enum.all?(view.blocked_by, &(&1.readiness == selected.readiness))
    assert Enum.zip_with(view.blocked_by, blocked_by, &(&1.edge === &2)) |> Enum.all?()

    assert [%Relationship{direction: :blocking, edge: ^blocking, readiness: :blocking}] = view.blocking
    assert Enum.all?(view.blocked_by ++ view.blocking, &(&1.selectable? and is_binary(&1.navigation_value)))
    refute Enum.any?(view.blocked_by ++ view.blocking, &(&1.navigation_value == &1.endpoint.identifier))

    assert Enum.map(view.base.capabilities, &{&1.label, &1.available?, &1.href}) == [
             {"Issue", true, issue_url(2)},
             {"Pull request", true, "https://github.com/owner/repo/pull/77"},
             {"Chat", true, "/chat/2"},
             {"Commands", true, "/decisions/2"}
           ]

    assert Enum.map(view.diagnostics, & &1.code) == [:missing_lane]
  end

  test "keeps missing and external endpoints diagnostic-only" do
    selected = node(2, :unknown)
    missing = identity(8)
    foreign = identity(9, owner: "other", repository: "repo", provider_id: "FOREIGN-9")

    missing_edge = %Edge{
      id: "missing",
      source: missing,
      target: selected.identity,
      source_key: key(missing),
      target_key: selected.key,
      kind: :native,
      state: :unknown,
      source_connection: :blocked_by,
      url: issue_url(8),
      text: "Missing configured-repository dependency",
      diagnostics: [Diagnostic.new(:unresolved_internal_dependency)]
    }

    external_edge = %Edge{
      id: "external",
      source: foreign,
      target: selected.identity,
      source_key: key(foreign),
      target_key: selected.key,
      kind: :external,
      state: :unknown,
      source_connection: :blocked_by,
      url: "https://github.com/other/repo/issues/9",
      text: "External dependency",
      diagnostics: [Diagnostic.new(:external_dependency)]
    }

    view =
      TicketContextAdapter.present(
        model([selected], [missing_edge, external_edge]),
        selected.identity,
        base_view(selected.identity),
        %{}
      )

    assert [external, missing] = Enum.sort_by(view.blocked_by, & &1.edge.id)
    refute external.selectable?
    assert external.navigation_value == nil
    assert external.outbound_url == "https://github.com/other/repo/issues/9"
    refute missing.selectable?
    assert missing.navigation_value == nil
    assert missing.outbound_url == nil

    unsafe_graph = model([selected], [%{external_edge | url: "https://github.com/owner/repo/issues/9"}])
    unsafe_view = TicketContextAdapter.present(unsafe_graph, selected.identity, base_view(selected.identity), %{})
    assert hd(unsafe_view.blocked_by).outbound_url == nil
  end

  test "fails closed when model selection and base context identities do not match exactly" do
    selected = node(2, :ready)
    graph = model([selected], [])

    for mismatched <- [
          identity(2, owner: "other"),
          identity(2, provider_id: "DIFFERENT"),
          %{identifier: "2"},
          nil
        ] do
      view = TicketContextAdapter.present(graph, selected.identity, base_view(mismatched), capabilities(selected.identity))

      assert view.status == :unavailable
      assert view.reason == :identity_mismatch
      assert view.selected == nil
      assert view.blocked_by == []
      assert view.blocking == []
      assert view.base.identity == nil
      assert view.base.capabilities == []
    end

    assert TicketContextAdapter.present(graph, identity(2, provider_id: "DIFFERENT"), base_view(selected.identity), %{}).reason ==
             :selection_unavailable

    stale_graph = %{graph | generations: %{planning: :unknown, activity: 1}}
    assert TicketContextAdapter.present(stale_graph, selected.identity, base_view(selected.identity), %{}).reason == :stale_scope

    duplicate_graph = %{graph | nodes: [selected, selected]}

    assert TicketContextAdapter.present(
             duplicate_graph,
             selected.identity,
             base_view(selected.identity),
             %{}
           ).reason == :selection_unavailable

    foreign_identity = identity(2, owner: "other", repository: "repo", provider_id: "FOREIGN-2")
    foreign_node = %{selected | key: key(foreign_identity), identity: foreign_identity}
    foreign_graph = model([foreign_node], [])

    assert TicketContextAdapter.present(
             foreign_graph,
             foreign_identity,
             base_view(foreign_identity),
             %{}
           ).reason == :selection_unavailable

    mismatched_generation = put_in(graph.root.generation, 6)

    assert TicketContextAdapter.present(
             mismatched_generation,
             selected.identity,
             base_view(selected.identity),
             %{}
           ).reason == :stale_scope
  end

  test "binds Chat and Commands to exact readable selected-member capabilities" do
    selected = node(2, :ready)
    graph = model([selected], [])

    cases = [
      {:chat, %{available?: true, destination: "/chat/2", identity: selected.identity, active?: false, readable?: true}, "Chat is inactive."},
      {:chat, %{available?: true, destination: "/chat/2", identity: selected.identity, active?: true, readable?: false}, "Chat is unreadable."},
      {:chat, %{available?: true, destination: "/chat/2", identity: identity(2, provider_id: "OTHER"), active?: true, readable?: true}, "Chat is unavailable for this ticket."},
      {:commands, %{available?: true, destination: "/decisions/2", identity: selected.identity, readable?: false}, "Commands are unreadable."},
      {:commands, %{available?: false, identity: selected.identity, reason: :stale}, "Commands are stale."},
      {:commands, %{available?: false, identity: selected.identity, reason: :unauthorized}, "Commands are unauthorized."}
    ]

    for {kind, capability, reason} <- cases do
      view =
        TicketContextAdapter.present(
          graph,
          selected.identity,
          base_view(selected.identity),
          %{kind => capability}
        )

      rendered = Enum.find(view.base.capabilities, &(&1.kind == kind))
      refute rendered.available?
      assert rendered.href == nil
      assert rendered.reason == reason
    end
  end

  defp model(nodes, edges) do
    root = identity(100)

    %BuildOrderViewModel{
      status: :ready,
      root: %{identity: root, generation: 7},
      nodes: nodes,
      edges: edges,
      generations: %{planning: 7, activity: 3}
    }
  end

  defp node(number, readiness, opts \\ []) do
    identity = identity(number)

    %Node{
      key: key(identity),
      identity: identity,
      title: "Ticket #{number}",
      url: issue_url(number),
      plan: %{},
      execution: %{},
      activity: %{},
      readiness: readiness,
      lane_icon: nil,
      status_icon: nil,
      health: %{},
      observed_at: %{},
      provenance: %{},
      diagnostics: Keyword.get(opts, :diagnostics, []),
      card: %{}
    }
  end

  defp edge(source, target, state, id) do
    %Edge{
      id: id,
      source: source.identity,
      target: target.identity,
      source_key: source.key,
      target_key: target.key,
      kind: :native,
      state: state,
      source_connection: :blocked_by,
      url: source.url,
      text: "#{source.title} blocks #{target.title}",
      diagnostics: []
    }
  end

  defp base_view(identity) do
    %BaseView{
      identity: identity,
      repository: "ignored",
      identifier: nil,
      title: "Selected ticket",
      description: "Bounded context",
      lifecycle: %{state: :open, reason: :none},
      detail: %{state: :stale, observed_at: nil, last_success_at: nil, last_attempt_at: nil},
      history: %{state: :restart_unknown, freshness: :unknown, observed_at: nil, source_health: %{}},
      progress: %{status: :unknown},
      latest_evidence: %{status: :unknown},
      logs: %{entries: [], truncated?: false, observed_at: nil},
      capabilities: []
    }
  end

  defp capabilities(identity) do
    %{
      issue: %{available?: true, destination: issue_url(2), identity: identity},
      pull_request: %{
        available?: true,
        destination: "https://github.com/owner/repo/pull/77",
        identity: identity,
        number: 77
      },
      chat: %{available?: true, destination: "/chat/2", identity: identity, active?: true, readable?: true},
      commands: %{available?: true, destination: "/decisions/2", identity: identity, readable?: true}
    }
  end

  defp readiness_for(1), do: :ready
  defp readiness_for(2), do: :blocking
  defp readiness_for(3), do: :terminal_unsatisfied
  defp readiness_for(4), do: :unknown
  defp readiness_for(5), do: :cyclic

  defp identity(number, overrides \\ []) do
    struct!(
      TrackerIdentity,
      Keyword.merge(
        [
          status: :joinable,
          kind: :github,
          owner: "owner",
          repository: "repo",
          provider_id: "ISSUE-#{number}",
          identifier: to_string(number),
          reason: nil
        ],
        overrides
      )
    )
  end

  defp key(identity), do: TrackerIdentity.github_key(identity)
  defp issue_url(number), do: "https://github.com/owner/repo/issues/#{number}"
end
