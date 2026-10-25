defmodule AiurWeb.DashboardLive.UnitsPanel do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_patch: 2]

  alias Aiur.OpenTicketSource
  alias AiurWeb.DashboardLive
  alias AiurWeb.DashboardLive.Controls
  alias AiurWeb.OperatorControlCenter.{AddAgentSubmission, AgentRoutingPreview, TicketsPresenter, UnitsPresenter, UnitsURL}

  @table_sort_columns %{
    "units" => ~w(id unit ticket latest),
    "fleet" => ~w(ticket state waiting latest elapsed commands),
    "tickets" => ~w(id title labels),
    "command-history" => ~w(command decision result),
    "ticket-logs" => ~w(activity detail when),
    "provider-routes" => ~w(route provider api)
  }

  @doc false
  @spec units_path(Phoenix.LiveView.Socket.t(), map()) :: String.t()
  def units_path(socket, selection) do
    params = UnitsURL.params(selection) |> maybe_put_table_sort(socket.assigns[:table_sort])
    Map.get(socket.assigns, :units_base_path, "/units") <> "?" <> URI.encode_query(params)
  end

  @doc false
  @spec assign_units_selection(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def assign_units_selection(socket, params) do
    selection = UnitsURL.decode(params)

    socket
    |> assign(:units_selection, selection)
    |> assign_units_view()
  end

  @doc false
  @spec maybe_canonicalize_units_url(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def maybe_canonicalize_units_url(socket, params) do
    selection = socket.assigns.units_selection
    expected = UnitsURL.params(selection) |> maybe_put_table_sort(socket.assigns[:table_sort]) |> Map.new()

    if socket.assigns.live_action == :index and not socket.assigns.conversation_from_route? and map_size(params) > 0 and
         params != expected do
      push_patch(socket, to: units_path(socket, selection), replace: true)
    else
      socket
    end
  end

  defp maybe_put_table_sort(params, nil), do: params
  defp maybe_put_table_sort(params, sort), do: params ++ [{"sort", sort}]

  @doc false
  @spec normalize_table_sort(term()) :: String.t() | nil
  def normalize_table_sort(sort) when is_binary(sort) do
    with [table, column, direction] <- String.split(sort, ":"),
         true <- direction in ["asc", "desc"],
         columns when is_list(columns) <- Map.get(@table_sort_columns, table),
         true <- column in columns do
      sort
    else
      _invalid -> nil
    end
  end

  def normalize_table_sort(_sort), do: nil

  @doc false
  @spec assign_units_view(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_units_view(socket) do
    catalog = socket.assigns.payload |> Map.get(:units, %{})
    view = UnitsPresenter.project(catalog, socket.assigns.units_selection)
    tickets_view = socket.assigns.payload |> Map.get(:tickets) |> TicketsPresenter.normalize()

    socket
    |> assign(:units_view, view)
    |> assign(:units_announcement, UnitsPresenter.announcement(view))
    |> assign(:units_count_label, units_count_label(view))
    |> assign(:tickets_view, tickets_view)
    |> assign_tickets_panel_view()
  end

  # The unfiltered projection stays in `tickets_view` and the panel renders the
  # searched one. Lookups — the add-agent modal, the ticket-context refresh —
  # then keep resolving a row the current query happens to hide, so a ticket
  # already open on screen does not go dead the moment the operator types.
  @doc false
  @spec assign_tickets_panel_view(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def assign_tickets_panel_view(socket) do
    # Reached during mount before the query default is assigned, so the query is
    # read defensively: no search yet means the unfiltered projection.
    query = Map.get(socket.assigns, :tickets_query, "")
    assign(socket, :tickets_panel_view, TicketsPresenter.search(socket.assigns.tickets_view, query))
  end

  # The modal opens on the routing the dispatcher would have applied, so the
  # operator confirms a prediction rather than filling in a blank form.
  #
  # The model falls back to `resolved_model` only when routing named no model at all.
  # `model` is the *requested* model and is `nil` whenever routing names just a
  # backend, which would preselect "Backend default" and hide the model that is
  # actually going to run — the prediction the Tickets table used to print in a
  # "Would route to" column, and which now lives only here.
  #
  # The requested model is preferred over the resolved one so a family alias stays
  # an alias. `CodingAgent.override_labels/0` seeds family tags and no versions
  # because "a pinned tag expires with its version"; preselecting `gpt-5.6-sol` for a
  # `codex:sol` routing entry would write that expiry onto the ticket and strand it
  # on 5.6 while every untouched ticket follows the alias forward.
  #
  # `normalize_selection/1` clamps whichever value wins to the backend's seedable
  # vocabulary (registry plus what its CLI reported), so an unlisted model falls back to the backend default.
  @doc false
  @spec add_agent_modal(map()) :: map()
  def add_agent_modal(row) do
    routing = row.routing

    selection = %{
      backend: routing.backend,
      model: routing.model || routing.resolved_model,
      effort: routing.effort,
      complexity: routing.complexity
    }

    build_add_agent_modal(row, selection)
  end

  @doc false
  @spec change_add_agent(map(), map()) :: map()
  def change_add_agent(modal, params) do
    backend = blank_to_nil(params["backend"]) || modal.selection.backend

    # A new backend invalidates the model and effort vocabularies, so a stale
    # selection is dropped rather than carried onto a backend that rejects it.
    # `normalize_selection/1` then clamps every field to what the daemon can
    # honour, because all four arrive from the browser.
    carry_over? = backend == modal.selection.backend

    selection = %{
      backend: backend,
      model: carry_over? && blank_to_nil(params["model"]),
      effort: carry_over? && blank_to_nil(params["effort"]),
      complexity: parse_complexity(params["complexity"])
    }

    build_add_agent_modal(modal, selection)
  end

  defp build_add_agent_modal(row, selection) do
    selection = AgentRoutingPreview.normalize_selection(selection)
    labels = Map.get(row, :labels, [])

    %{
      token: row.token,
      identifier: row.identifier,
      title: row.title,
      identity: Map.get(row, :identity),
      routing: Map.get(row, :routing, %{available?: false}),
      selection: selection,
      options: AgentRoutingPreview.options(selection.backend),
      labels: labels,
      plan: AgentRoutingPreview.plan(selection, labels),
      pending?: false,
      result: nil
    }
  end

  @doc false
  @spec finish_add_agent(Phoenix.LiveView.Socket.t(), map()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def finish_add_agent(socket, result) do
    modal = socket.assigns.add_agent_pending
    socket = socket |> assign(:add_agent_pending, nil) |> refresh_open_tickets({:ok, []})
    message = "Ticket ##{modal.identifier}: " <> AddAgentSubmission.message(result)

    if result.error do
      labels = AddAgentSubmission.labels(result, modal.labels)
      updated = build_add_agent_modal(Map.put(modal, :labels, labels), modal.selection)

      socket =
        retain_add_agent_result(socket, modal.token, Map.put(updated, :result, {:error, message}))

      {:noreply, assign(socket, :add_agent_notice, message)}
    else
      socket = retain_add_agent_result(socket, modal.token, nil)
      {:noreply, assign(socket, :add_agent_notice, message)}
    end
  end

  defp retain_add_agent_result(socket, token, modal) do
    case socket.assigns.add_agent_modal do
      %{token: ^token} -> assign(socket, :add_agent_modal, modal)
      _ -> socket
    end
  end

  # Confirming changed the tracker, so the panel's labels and its routing
  # prediction are both stale until the event stream carries it. Ask the
  # projection to re-list now, in addition to the delivery that is already on
  # its way.
  defp refresh_open_tickets(socket, result) when elem(result, 0) in [:ok, :partial] do
    OpenTicketSource.refresh()
    Aiur.Orchestrator.request_refresh(Controls.capacity_orchestrator())
    DashboardLive.reload_after_action(socket)
  rescue
    _error -> socket
  catch
    _kind, _reason -> socket
  end

  defp refresh_open_tickets(socket, _result), do: socket

  defp parse_complexity(value) do
    case blank_to_nil(value) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {complexity, ""} when complexity in 1..5 -> complexity
          _other -> nil
        end
    end
  end

  defp blank_to_nil(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp blank_to_nil(_value), do: nil

  # The Units panel counts what the panel actually shows, so a filtered view
  # never claims a fleet size the table below it does not contain. A partial
  # catalog is qualified rather than rounded down to a confident number.
  @doc false
  @spec units_count_label(map()) :: String.t()
  def units_count_label(view) do
    case Map.get(view, :count_status, :unavailable) do
      :loading -> "loading units…"
      :unavailable -> "units unavailable"
      :partial -> "at least #{unit_phrase(view)}"
      _exact -> unit_phrase(view)
    end
  end

  defp unit_phrase(view) do
    case view |> Map.get(:rows, []) |> length() do
      1 -> "1 unit"
      count -> "#{count} units"
    end
  end
end
