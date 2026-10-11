defmodule Aiur.BrowserHarness.TicketContextLive do
  use Phoenix.LiveView, layout: {Aiur.BrowserHarness.FixtureLayout, :app}

  alias Aiur.BuildOrder.Diagnostic
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.{TicketContextAdapter, TicketContextSelection}
  alias AiurWeb.BuildOrder.TicketContextPresenter.{LogEntry, View}
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}
  alias AiurWeb.OperatorControlCenter.BuildOrderTicketContext

  @observed_at ~U[2026-07-16 12:00:00Z]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:root_number, 100)
     |> assign(:generation, 7)
     |> assign(:members, [41, 42, 43])
     |> assign(:model, graph(100, 7, [41, 42, 43]))
     |> assign(:selection, TicketContextSelection.new(mount_epoch()))
     |> assign(:destinations_available?, true)
     |> assign(:stale_completion, nil)
     |> assign(:fixture_status, "Ticket context closed.")
     |> assign(:tick, 0)}
  end

  @impl true
  def handle_event("open-ticket-context", %{"member" => member}, socket) do
    selection = TicketContextSelection.open(socket.assigns.selection, socket.assigns.model, member)
    {:noreply, socket |> assign(:selection, selection) |> assign(:fixture_status, "Ticket context opened.")}
  end

  def handle_event("build-order-context-close", _params, socket) do
    {:noreply,
     socket
     |> assign(:selection, TicketContextSelection.close(socket.assigns.selection))
     |> assign(:fixture_status, "Ticket context closed.")}
  end

  def handle_event("build-order-context-replace", %{"member" => member}, socket) do
    previous = completion(socket.assigns.selection)
    selection = TicketContextSelection.replace(socket.assigns.selection, socket.assigns.model, member)

    {:noreply,
     socket
     |> assign(:selection, selection)
     |> assign(:stale_completion, previous)
     |> assign(:fixture_status, "Relationship replacement applied.")}
  end

  def handle_event("build-order-context-back", _params, socket) do
    previous = completion(socket.assigns.selection)
    selection = TicketContextSelection.back(socket.assigns.selection, socket.assigns.model)

    {:noreply,
     socket
     |> assign(:selection, selection)
     |> assign(:stale_completion, previous)
     |> assign(:fixture_status, "Relationship back navigation applied.")}
  end

  def handle_event("fixture-generation", _params, socket) do
    generation = socket.assigns.generation + 1
    model = graph(socket.assigns.root_number, generation, socket.assigns.members)
    selection = TicketContextSelection.reconcile(socket.assigns.selection, model)

    {:noreply,
     socket
     |> assign(:generation, generation)
     |> assign(:model, model)
     |> assign(:selection, selection)
     |> assign(:fixture_status, "Graph generation reconciled.")}
  end

  def handle_event("fixture-root", _params, socket) do
    root_number = socket.assigns.root_number + 100
    generation = socket.assigns.generation + 1
    model = graph(root_number, generation, socket.assigns.members)
    selection = TicketContextSelection.reconcile(socket.assigns.selection, model)

    {:noreply,
     socket
     |> assign(:root_number, root_number)
     |> assign(:generation, generation)
     |> assign(:model, model)
     |> assign(:selection, selection)
     |> assign(:fixture_status, "Build Order root changed.")}
  end

  def handle_event("fixture-remove-selected", _params, %{assigns: %{selection: %{selected: %TrackerIdentity{} = selected}}} = socket) do
    members = Enum.reject(socket.assigns.members, &(to_string(&1) == selected.identifier))
    generation = socket.assigns.generation + 1
    model = graph(socket.assigns.root_number, generation, members)
    selection = TicketContextSelection.reconcile(socket.assigns.selection, model)

    {:noreply,
     socket
     |> assign(:members, members)
     |> assign(:generation, generation)
     |> assign(:model, model)
     |> assign(:selection, selection)
     |> assign(:fixture_status, "Selected member removed.")}
  end

  def handle_event("fixture-remove-selected", _params, socket), do: {:noreply, socket}

  def handle_event("fixture-remove-upstream", _params, socket) do
    members = Enum.reject(socket.assigns.members, &(&1 == 41))
    generation = socket.assigns.generation + 1
    model = graph(socket.assigns.root_number, generation, members)
    selection = TicketContextSelection.reconcile(socket.assigns.selection, model)

    {:noreply,
     socket
     |> assign(:members, members)
     |> assign(:generation, generation)
     |> assign(:model, model)
     |> assign(:selection, selection)
     |> assign(:fixture_status, "Focused relationship removed.")}
  end

  def handle_event("fixture-remove-destination", _params, socket) do
    {:noreply,
     socket
     |> assign(:destinations_available?, false)
     |> assign(:fixture_status, "Focused destination removed.")}
  end

  def handle_event("fixture-stale-completion", _params, socket) do
    accepted? =
      case socket.assigns.stale_completion do
        %{token: token, identity: identity} -> TicketContextSelection.current_completion?(socket.assigns.selection, token, identity)
        _ -> false
      end

    status = if accepted?, do: "Stale completion applied.", else: "Stale completion rejected."
    {:noreply, assign(socket, :fixture_status, status)}
  end

  def handle_event("fixture-tick", _params, socket) do
    {:noreply, socket |> update(:tick, &(&1 + 1)) |> assign(:fixture_status, "Unrelated LiveView patch applied.")}
  end

  @impl true
  def render(assigns) do
    context = current_context(assigns.model, assigns.selection, assigns.destinations_available?)

    cards =
      Enum.map(assigns.model.nodes, fn node ->
        %{
          identity: node.identity,
          title: node.title,
          navigation: TicketContextSelection.navigation_value(assigns.model, node.identity),
          origin_id: TicketContextSelection.origin_id(assigns.model, node.identity)
        }
      end)

    assigns = assigns |> assign(:context, context) |> assign(:cards, cards)

    ~H"""
    <main class="app-shell" data-ticket-context-fixture="true">
      <header>
        <h1>Build Order ticket context fixture</h1>
        <p id="ticket-context-fixture-status" role="status">{@fixture_status}</p>
        <p id="ticket-context-fixture-generation">Root #{@root_number} · generation #{@generation} · tick #{@tick}</p>
      </header>

      <section aria-labelledby="ticket-context-fixture-cards">
        <h2 id="ticket-context-fixture-cards">Graph cards</h2>
        <div class="controls">
          <button
            :for={card <- @cards}
            id={card.origin_id}
            type="button"
            phx-click="open-ticket-context"
            phx-value-member={card.navigation}
            data-ticket-identifier={card.identity.identifier}
          >
            {card.title}
          </button>
        </div>
      </section>

      <div class="controls" aria-label="Ticket context fixture transitions">
        <button id="fixture-generation" type="button" phx-click="fixture-generation">Advance graph generation</button>
        <button id="fixture-root" type="button" phx-click="fixture-root">Switch Build Order root</button>
        <button id="fixture-remove-selected" type="button" phx-click="fixture-remove-selected">Remove selected member</button>
        <button id="fixture-remove-upstream" type="button" phx-click="fixture-remove-upstream">Remove upstream relationship</button>
        <button id="fixture-remove-destination" type="button" phx-click="fixture-remove-destination">Remove Chat destination</button>
        <button id="fixture-stale-completion" type="button" phx-click="fixture-stale-completion">Apply stale detail completion</button>
        <button id="fixture-tick" type="button" phx-click="fixture-tick">Apply unrelated patch</button>
      </div>

      <BuildOrderTicketContext.build_order_ticket_context
        :if={@context}
        id="fixture-ticket-context"
        context={@context}
        selection={@selection}
      />
    </main>
    """
  end

  defp current_context(model, %{status: :open, selected: %TrackerIdentity{} = selected}, destinations_available?) do
    model
    |> TicketContextAdapter.present(selected, base_context(selected), capabilities(selected, destinations_available?))
    |> case do
      %{status: :available} = context -> context
      _unavailable -> nil
    end
  end

  defp current_context(_model, _selection, _destinations_available?), do: nil

  defp base_context(%TrackerIdentity{} = identity) do
    {title, detail_state, history_state} = ticket_states(identity.identifier)

    %View{
      identity: identity,
      repository: "owner/repo",
      identifier: identity.identifier,
      title: title,
      description: "A bounded description for the browser fixture.",
      lifecycle: %{state: :open, reason: :none},
      detail: %{
        state: detail_state,
        observed_at: @observed_at,
        last_success_at: @observed_at,
        last_attempt_at: @observed_at
      },
      history: %{
        state: history_state,
        freshness: if(history_state == :stale, do: :stale, else: :fresh),
        observed_at: @observed_at,
        source_health: %{activity: :available, history: :available}
      },
      progress: %{
        status: :known,
        percent: 40,
        source: :checkin,
        occurred_at: @observed_at,
        observed_at: @observed_at,
        provenance: %{run_id: "fixture"}
      },
      latest_evidence: %{
        status: :known,
        source: %{kind: :agent_event, name: "progress.checkin"},
        occurred_at: @observed_at,
        observed_at: @observed_at,
        provenance: %{}
      },
      logs: %{
        entries: [
          %LogEntry{
            kind: :progress,
            label: "Progress updated",
            source: :exchange,
            occurred_at: @observed_at,
            observed_at: @observed_at
          }
        ],
        truncated?: false,
        observed_at: @observed_at
      },
      capabilities: []
    }
  end

  defp ticket_states("41"), do: {"Upstream ticket", :available, :available}
  defp ticket_states("43"), do: {"Downstream ticket", :stale, :stale}
  defp ticket_states(_identifier), do: {"Configured ticket", :available, :available}

  defp capabilities(%TrackerIdentity{} = identity, false) do
    identity
    |> capabilities(true)
    |> Map.put(:chat, %{available?: false, identity: identity, reason: :stale})
  end

  defp capabilities(%TrackerIdentity{identifier: "43"} = identity, true) do
    %{
      issue: %{available?: true, destination: issue_url(identity), identity: identity},
      pull_request: %{available?: false, identity: identity, reason: :not_opened},
      chat: %{available?: false, identity: identity, reason: :stale},
      commands: %{available?: false, identity: identity, reason: :unauthorized}
    }
  end

  defp capabilities(%TrackerIdentity{} = identity, true) do
    %{
      issue: %{available?: true, destination: issue_url(identity), identity: identity},
      pull_request: %{available?: false, identity: identity, reason: :not_opened},
      chat: %{available?: true, destination: "/chat/#{identity.owner}/#{identity.repository}/#{identity.identifier}", identity: identity, active?: true, readable?: true},
      commands: %{available?: true, destination: "/commands/#{identity.identifier}", identity: identity, readable?: true}
    }
  end

  defp mount_epoch, do: "ticket-context-mount-#{System.unique_integer([:positive, :monotonic])}"

  defp graph(root_number, generation, members) do
    nodes = Enum.map(members, &member/1)
    node_keys = MapSet.new(nodes, & &1.key)

    edges =
      [
        edge(identity(41), identity(42), :blocking, :native, []),
        edge(identity(42), identity(43), :terminal_unsatisfied, :native, []),
        edge(identity(9, owner: "other", repository: "repo", provider_id: "FOREIGN-9"), identity(42), :unknown, :external, [
          Diagnostic.new(:external_dependency)
        ]),
        edge(identity(8), identity(42), :unknown, :native, [Diagnostic.new(:unresolved_internal_dependency)])
      ]
      |> Enum.filter(&MapSet.member?(node_keys, &1.target_key))

    %BuildOrderViewModel{
      status: :ready,
      root: %{identity: identity(root_number), generation: generation},
      nodes: nodes,
      edges: edges,
      generations: %{planning: generation, activity: generation}
    }
  end

  defp member(number) do
    identity = identity(number)

    %Node{
      key: TrackerIdentity.github_key(identity),
      identity: identity,
      title: ticket_states(identity.identifier) |> elem(0),
      url: issue_url(identity),
      plan: %{},
      execution: %{},
      activity: %{},
      readiness: readiness(number),
      lane_icon: nil,
      status_icon: nil,
      health: %{},
      observed_at: %{},
      provenance: %{},
      card: %{}
    }
  end

  defp edge(source, target, state, kind, diagnostics) do
    %Edge{
      id: "#{kind}-#{source.identifier || "missing"}-#{target.identifier || "missing"}",
      source: source,
      target: target,
      source_key: TrackerIdentity.github_key(source),
      target_key: TrackerIdentity.github_key(target),
      kind: kind,
      state: state,
      source_connection: :blocked_by,
      url: issue_url(source),
      text: "Controlled browser-fixture relationship",
      diagnostics: diagnostics
    }
  end

  defp readiness(42), do: :unknown
  defp readiness(43), do: :terminal_unsatisfied
  defp readiness(_number), do: :ready

  defp completion(%{status: :open, request_token: token, selected: %TrackerIdentity{} = identity}),
    do: %{token: token, identity: identity}

  defp completion(_selection), do: nil

  defp issue_url(%TrackerIdentity{owner: owner, repository: repository, identifier: identifier}),
    do: "https://github.com/#{owner}/#{repository}/issues/#{identifier}"

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
