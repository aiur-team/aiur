defmodule AiurWeb.OperatorControlCenter.BuildOrderTicketContextTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.BuildOrder.Diagnostic
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.TicketContextAdapter.{Relationship, View}
  alias AiurWeb.BuildOrder.TicketContextPresenter.View, as: BaseView
  alias AiurWeb.BuildOrder.TicketContextSelection
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}
  alias AiurWeb.OperatorControlCenter.BuildOrderTicketContext

  test "renders named semantic relationships with fixed navigation-only callbacks" do
    html =
      render_component(&BuildOrderTicketContext.build_order_ticket_context/1, %{
        id: "build-order-ticket-context",
        context: context(),
        selection: selection()
      })

    assert html =~ ~s(role="dialog")
    assert html =~ ~s(data-focus-key="navigation-5")
    assert html =~ ~s(data-origin-id="build-order-card-root-member")
    assert html =~ ~s(phx-click="build-order-context-close")
    assert html =~ ~s(phx-click="build-order-context-back")
    assert html =~ ~s(phx-click="build-order-context-replace")
    assert html =~ ~s(phx-value-member="member-upstream")
    assert html =~ "Blocked by"
    assert html =~ "Blocking"
    assert html =~ ~s(<ul class="build-order-context-relationships")
    assert html =~ "Upstream blocker → selected ticket"
    assert html =~ "Selected ticket → downstream ticket"

    for label <- ["Cleared", "Blocking", "Terminal unsatisfied", "Unknown", "Cyclic"] do
      assert html =~ label
    end

    assert html =~ "Affected readiness"
    assert html =~ "Build lane label is missing."
    assert html =~ "Dependency is outside the configured repository."
    assert html =~ ~s(href="https://github.com/other/repo/issues/9")
    assert html =~ ~s(target="_blank")
    assert html =~ ~s(rel="noopener noreferrer")
    refute html =~ ~s(phx-value-member="member-external")
    refute html =~ ~s(phx-value-member="member-missing")
    refute html =~ ~s(<form)

    for mutation <- [
          "pause-agent",
          "resume-agent",
          "open-chat",
          "answer-decision",
          "change-capacity",
          "change-membership",
          "change-label",
          "change-phase",
          "change-lane",
          "change-lifecycle",
          "change-dependency"
        ] do
      refute html =~ ~s(phx-click="#{mutation}")
    end
  end

  test "keeps both named relationship sections when they are empty" do
    empty = %{context() | blocked_by: [], blocking: []}

    html =
      render_component(&BuildOrderTicketContext.build_order_ticket_context/1, %{
        id: "empty-build-order-ticket-context",
        context: empty,
        selection: %{selection() | history: []}
      })

    assert html =~ "Blocked by"
    assert html =~ "No upstream blockers are available."
    assert html =~ "Blocking"
    assert html =~ "No downstream tickets are available."
    refute html =~ ~s(phx-click="build-order-context-back")
  end

  test "revalidates relationship links and controlled diagnostics at the component boundary" do
    view = context()
    [internal, external | rest] = view.blocked_by

    unsafe_external = %{
      external
      | outbound_url: "https://github.com/owner/repo/issues/9",
        edge: %{
          external.edge
          | diagnostics: [%Diagnostic{code: :external_dependency, text: "raw provider secret"}]
        }
    }

    forged_navigation = %{internal | navigation_value: "https://example.test/mutate"}
    invalid_state = %{hd(rest) | edge: %{hd(rest).edge | state: :made_up}, label: "Invalid state row"}

    html =
      render_component(&BuildOrderTicketContext.build_order_ticket_context/1, %{
        id: "bounded-build-order-ticket-context",
        context: %{view | blocked_by: [unsafe_external, forged_navigation, invalid_state]},
        selection: selection()
      })

    refute html =~ ~s(href="https://github.com/owner/repo/issues/9")
    refute html =~ "raw provider secret"
    refute html =~ "https://example.test/mutate"
    refute html =~ "Invalid state row"
    assert html =~ "Dependency is outside the configured repository."
  end

  test "renders a truthful warning when a relationship direction exceeds 100 rows" do
    view = context()
    template = hd(view.blocked_by)

    rows =
      Enum.map(1..101, fn index ->
        %{
          template
          | edge: %{template.edge | id: "bounded-edge-#{index}"},
            label: "Bounded relationship #{index}",
            navigation_value: "bounded-member-#{index}"
        }
      end)

    html =
      render_component(&BuildOrderTicketContext.build_order_ticket_context/1, %{
        id: "truncated-build-order-ticket-context",
        context: %{
          view
          | blocked_by: rows,
            blocked_by_metadata: %{total: 101, shown: 100, truncated?: true},
            blocking: [],
            blocking_metadata: %{total: 0, shown: 0, truncated?: false}
        },
        selection: selection()
      })

    document = Floki.parse_fragment!(html)
    assert document |> Floki.find("#truncated-build-order-ticket-context-blocked-by + .ticket-context-status") |> Floki.text() =~ "showing 100 of 101 relationships"
    assert length(Floki.find(document, "#truncated-build-order-ticket-context-blocked-by ~ ul > li")) == 100
    refute html =~ "Bounded relationship 101</button>"
  end

  test "preserves every base detail and history presentation state" do
    for {detail, expected} <- [
          {:available, "Ticket detail is current."},
          {:stale, "Ticket detail is stale."},
          {:missing, "Ticket detail has not been loaded."},
          {:unavailable, "Ticket detail is unavailable."}
        ] do
      html = render(detail, :available)
      assert html =~ expected
      assert html =~ "Logs"
      assert html =~ "Destinations"
    end

    for {history, expected} <- [
          {:available, "Ticket history is current."},
          {:known_empty, "No history has been recorded yet."},
          {:missing_source, "Ticket history is not available from its source."},
          {:restart_unknown, "Activity continuity is unknown after restart."},
          {:stale, "Ticket history is stale."},
          {:unavailable, "Ticket history is unavailable."}
        ] do
      assert render(:available, history) =~ expected
    end
  end

  defp render(detail, history) do
    view = context()
    base = %{view.base | detail: %{view.base.detail | state: detail}, history: %{view.base.history | state: history}}

    render_component(&BuildOrderTicketContext.build_order_ticket_context/1, %{
      id: "build-order-ticket-context-#{detail}-#{history}",
      context: %{view | base: base},
      selection: selection()
    })
  end

  defp context do
    selected = member(42, :terminal_unsatisfied, [Diagnostic.new(:missing_lane)])
    upstream = member(41, :ready)
    downstream = member(43, :blocking)
    external = identity(9, owner: "other", repository: "repo", provider_id: "FOREIGN-9")
    missing = identity(8)

    rows = [
      relationship(:blocked_by, edge(upstream.identity, selected.identity, :cleared, "cleared"), upstream.identity, upstream.title, selected.readiness, navigation_value: "member-upstream"),
      relationship(
        :blocked_by,
        edge(external, selected.identity, :blocking, "external", :external, [Diagnostic.new(:external_dependency)]),
        external,
        "Ticket 9",
        selected.readiness,
        outbound_url: "https://github.com/other/repo/issues/9"
      ),
      relationship(
        :blocked_by,
        edge(missing, selected.identity, :terminal_unsatisfied, "missing", :native, [Diagnostic.new(:unresolved_internal_dependency)]),
        missing,
        "Ticket 8",
        selected.readiness
      ),
      relationship(:blocked_by, edge(identity(7), selected.identity, :unknown, "unknown"), identity(7), "Ticket 7", selected.readiness),
      relationship(:blocked_by, edge(identity(6), selected.identity, :cyclic, "cyclic"), identity(6), "Ticket 6", selected.readiness)
    ]

    blocking =
      relationship(:blocking, edge(selected.identity, downstream.identity, :blocking, "downstream"), downstream.identity, downstream.title, downstream.readiness, navigation_value: "member-downstream")

    %View{
      status: :available,
      base: base_view(selected.identity),
      selected: selected,
      blocked_by: rows,
      blocking: [blocking],
      diagnostics: selected.diagnostics ++ Enum.flat_map(rows, & &1.edge.diagnostics)
    }
  end

  defp relationship(direction, edge, endpoint, label, readiness, opts \\ []) do
    navigation_value = Keyword.get(opts, :navigation_value)

    %Relationship{
      direction: direction,
      edge: edge,
      endpoint: endpoint,
      label: label,
      readiness: readiness,
      selectable?: is_binary(navigation_value),
      navigation_value: navigation_value,
      outbound_url: Keyword.get(opts, :outbound_url)
    }
  end

  defp edge(source, target, state, id, kind \\ :native, diagnostics \\ []) do
    %Edge{
      id: id,
      source: source,
      target: target,
      source_key: TrackerIdentity.github_key(source),
      target_key: TrackerIdentity.github_key(target),
      kind: kind,
      state: state,
      source_connection: :blocked_by,
      url: nil,
      text: "Controlled relationship #{id}",
      diagnostics: diagnostics
    }
  end

  defp member(number, readiness, diagnostics \\ []) do
    identity = identity(number)

    %Node{
      key: TrackerIdentity.github_key(identity),
      identity: identity,
      title: "Ticket #{number}",
      plan: %{},
      execution: %{},
      activity: %{},
      readiness: readiness,
      lane_icon: nil,
      status_icon: nil,
      health: %{},
      observed_at: %{},
      provenance: %{},
      diagnostics: diagnostics,
      card: %{}
    }
  end

  defp base_view(identity) do
    %BaseView{
      identity: identity,
      repository: "owner/repo",
      identifier: "42",
      title: "Configured ticket",
      description: "Bounded description",
      lifecycle: %{state: :open, reason: :none},
      detail: %{state: :available, observed_at: nil, last_success_at: nil, last_attempt_at: nil},
      history: %{state: :available, freshness: :fresh, observed_at: nil, source_health: %{activity: :available, history: :available}},
      progress: %{status: :unknown, percent: nil, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}},
      latest_evidence: %{status: :unknown, source: nil, occurred_at: nil, observed_at: nil, provenance: %{}},
      logs: %{entries: [], truncated?: false, observed_at: nil},
      capabilities: []
    }
  end

  defp selection do
    %TicketContextSelection{
      status: :open,
      root_key: {:github, "owner", "repo", "ROOT"},
      generation: 7,
      selected: identity(42),
      history: [identity(41)],
      origin_id: "build-order-card-root-member",
      request_epoch: "component-mount",
      request_sequence: 5,
      request_token: "request-current",
      focus_revision: 5
    }
  end

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
end
