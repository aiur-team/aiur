defmodule AiurWeb.OperatorControlCenterComponentsFixtures do
  @moduledoc false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Aiur.BuildOrder.Icon
  alias AiurWeb.BuildOrder.RouteState
  alias AiurWeb.BuildOrderViewModel
  alias AiurWeb.BuildOrderViewModel.{Edge, Node}

  alias AiurWeb.OperatorControlCenter.{BuildOrderSelected, DecisionInbox, History}

  def fleet_row(identifier, waiting_reason, attrs \\ []) do
    Map.merge(
      %{
        issue_identifier: identifier,
        title: "Ticket #{identifier}",
        state: "in-progress",
        work_state: :working,
        waiting_reason: waiting_reason,
        runtime_seconds: 60,
        open_decision_count: 0
      },
      Map.new(attrs)
    )
  end

  def render_selected(model) do
    {route_state, _effects} = RouteState.new("mount-1") |> RouteState.navigate("1567")

    render_component(&BuildOrderSelected.build_order_selected/1, %{
      route_state: route_state,
      model: model,
      now: ~U[2026-08-10 12:00:00Z],
      analytics_scope: %{state: :none},
      usage_scope: %{state: :none}
    })
  end

  def unresolved_model(status) do
    %BuildOrderViewModel{status: status, summary: unresolved_summary()}
  end

  def unresolved_summary, do: %{resolved_summary() | resolved?: false}

  def resolved_summary do
    %{resolved?: true, members: 0, edges: 0, external_edges: 0, lanes: %{}, phases: %{}}
  end

  def action_decision(attrs) do
    defaults = %{
      decision_id: "dec-action",
      version: 1,
      kind: "architecture",
      reversibility: :reversible,
      decision_status: :open,
      delivery_status: :not_dispatched,
      lifecycle: :recorded,
      options: [%{id: "ship", label: "Ship it", description: "Proceed", risk: "low"}],
      recommendation: %{option_id: "ship", reason: "Smallest safe change"},
      answer: nil,
      retryable: false,
      failure_reason: nil
    }

    defaults |> Map.merge(Map.new(attrs)) |> put_open()
  end

  def action_answer(kind, attrs \\ []) do
    defaults = %{
      action_id: "act-#{kind}",
      decision_version: 1,
      selected_option_id: "ship",
      custom_response: nil,
      rationale: nil,
      actor: %{kind: kind, id: Atom.to_string(kind)},
      accepted_at: ~U[2026-07-12 13:00:00Z]
    }

    Map.merge(defaults, Map.new(attrs))
  end

  def inbox_decision(decision_id, attrs \\ []) do
    defaults = %{
      decision_id: decision_id,
      version: 1,
      ticket: %{identifier: "AIUR-987", title: "OCC"},
      source: %{agent_id: "agent-987"},
      kind: "architecture",
      authority: :human_required,
      urgency: :normal,
      blocking: false,
      reversibility: :reversible,
      question: "Question #{decision_id}",
      context: %{short: nil, long_markdown: nil},
      options: [%{id: "ship", label: "Ship it", description: "Proceed", risk: "low"}],
      recommendation: nil,
      consequence_of_delay: nil,
      artifacts: [],
      created_at: ~U[2026-07-12 12:00:00Z],
      decision_status: :open,
      delivery_status: :not_dispatched,
      answer: nil,
      retryable: false,
      failure_reason: nil,
      superseded?: false,
      lifecycle: :recorded
    }

    defaults |> Map.merge(Map.new(attrs)) |> put_open()
  end

  # Hand-built rows skip DecisionPresenter, so derive its `open?` field from the row's own fields.
  # Keep this in step with `RetainedIndex.open?/1` (rows carry no `legacy_attention`).
  defp put_open(row) do
    Map.put_new_lazy(row, :open?, fn ->
      row.decision_status in [:open, :deferred] or
        (row.decision_status == :expired and Map.get(row, :blocking, false) and is_nil(row.answer))
    end)
  end

  def render_history(decisions, opts \\ []) do
    render_component(&History.history/1, %{
      rows: decisions,
      loaded: length(decisions),
      total: Keyword.get(opts, :total),
      has_more: Keyword.get(opts, :has_more, false),
      provider_health: :ok,
      expanded_id: Keyword.get(opts, :expanded_id),
      writable: Keyword.get(opts, :writable, false),
      time_zone: Keyword.get(opts, :time_zone, "Etc/UTC")
    })
  end

  def render_inbox(decisions, filter, retained_counts \\ nil) do
    awaiting = Enum.count(decisions, &(&1.decision_status == :open))

    retained_counts =
      retained_counts ||
        %{
          total: length(decisions),
          open: awaiting,
          awaiting: awaiting,
          blocking: Enum.count(decisions, &(&1.blocking and &1.decision_status == :open)),
          awaiting_blocking: Enum.count(decisions, &(&1.blocking and &1.decision_status == :open))
        }

    render_component(&DecisionInbox.decision_inbox/1, %{
      decisions: decisions,
      selected_decision_id: nil,
      filter: filter,
      now: ~U[2026-07-12 13:00:00Z],
      history: [],
      action_states: %{},
      writable: false,
      provider_health: :ok,
      retained_counts: retained_counts
    })
  end

  # --- Build Order grid fixtures ---------------------------------------------
  def sample_view_model do
    nodes = [
      node(:bo010, "BO-010", "plan-graph", 3,
        complexity: 3,
        status_icon: %Icon{key: :status_completed, text: "Completed"},
        progress: :unknown
      ),
      node(:bo012, "BO-012", "plan-graph", 4,
        complexity: 4,
        status_icon: %Icon{key: :status_working, text: "Agent working"},
        progress: 40
      ),
      node(:dash1, "DASH-001", "dashboard-ui", 3,
        complexity: 3,
        status_icon: %Icon{key: :status_ready, text: "Ready"}
      ),
      node(:dash2, "DASH-002", "dashboard-ui", 4,
        complexity: 2,
        status_icon: %Icon{key: :status_blocking, text: "Blocked by an open dependency"}
      )
    ]

    edges = [
      edge("e-cleared", :bo010, :bo012, :cleared),
      edge("e-blocking", :dash2, :bo010, :blocking)
    ]

    %AiurWeb.BuildOrderViewModel{status: :ready, nodes: nodes, edges: edges}
  end

  def node(key, identifier, lane, phase, opts) do
    %Node{
      key: key,
      identity: nil,
      title: Keyword.get(opts, :title, "Node #{identifier}"),
      plan: %{complexity: Keyword.get(opts, :complexity, :unknown)},
      execution: %{},
      activity: %{},
      readiness: :ready,
      lane_icon: nil,
      status_icon: Keyword.get(opts, :status_icon),
      health: %{},
      observed_at: %{},
      provenance: %{},
      diagnostics: [],
      card: %{
        identifier: identifier,
        lane: lane,
        phase: phase,
        status_text: Keyword.get(opts, :status_text),
        lifecycle: %{state: :open, state_reason: :none},
        execution_state: :idle,
        agent_stage: nil,
        progress: Keyword.get(opts, :progress, :unknown),
        # A bare integer in a fixture is a live reading unless the test says otherwise.
        progress_freshness: Keyword.get(opts, :progress_freshness, if(is_integer(Keyword.get(opts, :progress)), do: :fresh, else: :unknown))
      }
    }
  end

  def edge(id, source_key, target_key, state) do
    %Edge{
      id: id,
      source: nil,
      target: nil,
      source_key: source_key,
      target_key: target_key,
      kind: :native,
      state: state,
      source_connection: nil,
      text: nil,
      diagnostics: []
    }
  end
end
