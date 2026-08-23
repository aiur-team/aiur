defmodule AiurWeb.OperatorControlCenter.BuildOrderCatalog do
  @moduledoc "Catalog surface and explicit catalog-state rendering for Build Order routes."

  use Phoenix.Component

  alias Aiur.BuildOrder.{Catalog, ProgressRenderer, RootSummary}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.RouteState

  attr(:route_state, :any, required: true)
  attr(:now, :any, required: true)

  @spec build_order_catalog(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_catalog(assigns) do
    ~H"""
    <section class="bo-surface bo-surface-flush" aria-label="Build Orders">
      <.catalog_entries snapshot={RouteState.catalog_snapshot(@route_state)} />
    </section>
    """
  end

  @spec catalog_state(term()) :: :loading | :stale_lkg | :invalid_lkg | :empty | :ready | :stale | :invalid | :unavailable
  def catalog_state(nil), do: :loading

  def catalog_state(%Snapshot{data: %Catalog{entries: entries}, health: %{state: :stale}})
      when is_list(entries),
      do: :stale_lkg

  def catalog_state(%Snapshot{data: %Catalog{}, health: %{state: :structurally_invalid}}),
    do: :invalid_lkg

  def catalog_state(%Snapshot{data: %Catalog{entries: []}}), do: :empty
  def catalog_state(%Snapshot{data: %Catalog{}}), do: :ready
  def catalog_state(%Snapshot{health: %{state: :stale}}), do: :stale
  def catalog_state(%Snapshot{health: %{state: :structurally_invalid}}), do: :invalid
  def catalog_state(%Snapshot{}), do: :unavailable
  def catalog_state(_snapshot), do: :unavailable

  attr(:snapshot, :any, default: nil)

  defp catalog_entries(%{snapshot: %Snapshot{data: %Catalog{entries: entries} = catalog} = snapshot} = assigns) do
    assigns =
      assigns
      |> assign(:entries, entries)
      |> assign(:catalog, catalog)
      |> assign(:search_paths, catalog.search_paths)
      |> assign(:catalog_notice, catalog_notice(snapshot))

    ~H"""
    <div class="bo-catalog">
      <div :if={@catalog_notice} class="bo-state-card" role="status">
        <h3>{@catalog_notice.title}</h3>
        <p>{@catalog_notice.message}</p>
      </div>

      <table :if={@entries != []} id="build-orders-table" class="bo-catalog-table" phx-hook="SortableTable" data-sort-table="build-orders" data-sort-client-only>
        <thead>
          <tr>
            <th scope="col" data-sort-key="title">Title</th>
            <th scope="col" data-sort-key="progress" data-sort-type="number" class="bo-catalog-progress-head">Progress</th>
            <th scope="col" data-sort-key="tickets" data-sort-type="number" class="bo-catalog-num">Tickets</th>
            <th scope="col" data-sort-key="epics" data-sort-type="number" class="bo-catalog-num">Epics</th>
            <th scope="col" data-sort-key="waves" data-sort-type="number" class="bo-catalog-num">Waves</th>
          </tr>
        </thead>
        <tbody>
          <%= for entry <- @entries do %>
          <% progress = ProgressRenderer.html(entry) %>
          <tr class={if(entry.completed?, do: "bo-catalog-completed", else: "bo-catalog-active")} data-sort-id={catalog_sort_id(entry)}>
            <td data-sort-value={entry.title}>
              <span class="bo-catalog-icon" aria-label={catalog_icon_label(entry.icon)}>{catalog_icon(entry.icon)}</span>
              <.link :if={catalog_path(entry)} patch={catalog_path(entry)} class="bo-catalog-link">{entry.title}</.link>
              <span :if={is_nil(catalog_path(entry))} class="bo-catalog-invalid">{entry.title}</span>
            </td>
            <td class="bo-catalog-progress-cell" data-sort-value={progress.percent || ""}>
              <.catalog_progress progress={progress} />
            </td>
            <td class="bo-catalog-num mono num" data-sort-value={entry.member_count}>
              <%!-- Tickets come from the cheap read, so the labelled-read cause does not
                    apply to them. An unresolved ticket count still says "Unresolved"
                    rather than a cryptic "—": the same unknown must not render two ways. --%>
              <.catalog_count count={entry.member_count} label="Tickets" />
            </td>
            <td class="bo-catalog-num mono num" data-sort-value={entry.epic_count}>
              <.catalog_count
                count={entry.epic_count}
                label="Epics"
                failure={@catalog.count_resolution_failure}
                reset_at={@catalog.count_resolution_reset_at}
              />
            </td>
            <td class="bo-catalog-num mono num" data-sort-value={entry.phase_count}>
              <.catalog_count
                count={entry.phase_count}
                label="Waves"
                failure={@catalog.count_resolution_failure}
                reset_at={@catalog.count_resolution_reset_at}
              />
            </td>
          </tr>
          <% end %>
        </tbody>
      </table>

      <div :if={@entries == []} class="bo-state-card">
        <h3>No Build Orders for this repository</h3>
        <p>No packs matching this daemon's tracked repository were found.</p>
        <p :if={@search_paths != []}>
          Searched: {Enum.join(@search_paths, ", ")}
        </p>
      </div>

      <ul :if={@catalog.diagnostics != []} class="bo-diagnostics" aria-label="Catalog diagnostics">
        <li :for={diagnostic <- @catalog.diagnostics}>{diagnostic.text}</li>
      </ul>
    </div>
    """
  end

  defp catalog_entries(assigns) do
    assigns = assign(assigns, :catalog_state, catalog_state(assigns.snapshot))

    ~H"""
    <div class="bo-state-card" role={catalog_state_role(@catalog_state)}>
      <h3>{catalog_state_title(@catalog_state)}</h3>
      <p>{catalog_state_message(@catalog_state)}</p>
    </div>
    """
  end

  defp catalog_progress(assigns) do
    ~H"""
    <div
      :if={is_integer(@progress.percent)}
      class={["bo-catalog-progress", @progress.state == :partial && "bo-catalog-progress-partial"]}
      data-progress-state={@progress.state}
      role="img"
      aria-label={@progress.aria_label}
      title={@progress.title}
    >
      <span class="bo-catalog-progress-track"><i style={"width:#{@progress.percent}%"}></i></span>
      <span class="bo-catalog-progress-label mono num">{@progress.label}</span>
      <span :if={@progress.coverage} class="bo-catalog-progress-coverage mono num">{@progress.coverage}</span>
    </div>
    <div
      :if={is_nil(@progress.percent) and @progress.state == :unresolved}
      class="bo-catalog-progress is-unknown"
      data-progress-state={@progress.state}
      role="img"
      aria-label={@progress.aria_label}
      title={@progress.title}
    >
      <span class="bo-catalog-progress-track"></span>
      <span class="bo-catalog-progress-label mono num">{@progress.label}</span>
    </div>
    <span
      :if={@progress.state == :empty}
      class="bo-catalog-progress-empty mono"
      data-progress-state={@progress.state}
      role="img"
      aria-label={@progress.aria_label}
      title={@progress.title}
    >{@progress.label}</span>
    <span
      :if={is_nil(@progress.percent) and @progress.state not in [:unresolved, :empty]}
      class="bo-catalog-invalid"
      data-progress-state={@progress.state}
      role="img"
      aria-label={@progress.aria_label}
      title={@progress.title}
    >{@progress.label}</span>
    """
  end

  defp catalog_sort_id(%{identity: %TrackerIdentity{identifier: identifier}}), do: identifier
  defp catalog_sort_id(entry), do: entry.title

  attr(:count, :any, required: true)
  attr(:label, :string, required: true)
  attr(:failure, :atom, default: nil)
  attr(:reset_at, :any, default: nil)

  defp catalog_count(assigns) do
    assigns =
      assign(assigns, :unresolved, count_failure_presentation(assigns.label, assigns.failure, assigns.reset_at))

    ~H"""
    <%= if is_integer(@count) do %>
      {@count}
    <% else %>
      <span
        class="bo-catalog-count-unresolved"
        data-count-state="unresolved"
        role="img"
        aria-label={@unresolved.aria_label}
        title={@unresolved.title}
      >
        {@unresolved.text}
      </span>
    <% end %>
    """
  end

  # Every class states a cause the projection actually established. The final
  # clause is the honest unknown, not a default dressed as a diagnosis: an
  # unrecognised failure renders "Unresolved" rather than sending an operator to
  # GitHub's status page over their own expired token (#2250).
  defp count_failure_presentation(label, :budget, reset_at),
    do: %{
      text: "Budget exhausted" <> reset_suffix(reset_at),
      aria_label: "#{label} not counted: budget exhausted" <> reset_suffix(reset_at),
      title:
        "#{label} could not be counted because the planning query budget was exhausted." <>
          reset_sentence(reset_at)
    }

  defp count_failure_presentation(label, :rate_limited, reset_at),
    do: %{
      text: "Rate limited" <> reset_suffix(reset_at),
      aria_label: "#{label} not counted: rate limited" <> reset_suffix(reset_at),
      title: "#{label} could not be counted because the tracker rate limited the read." <> reset_sentence(reset_at)
    }

  defp count_failure_presentation(label, :timeout, _reset_at),
    do: %{
      text: "Timed out",
      aria_label: "#{label} not counted: timed out",
      title: "#{label} could not be counted because the planning request timed out."
    }

  defp count_failure_presentation(label, :unreachable, _reset_at),
    do: %{
      text: "Unreachable",
      aria_label: "#{label} not counted: unreachable",
      title: "#{label} could not be counted because the connection to the tracker was refused or dropped."
    }

  defp count_failure_presentation(label, :permission, _reset_at),
    do: %{
      text: "Not authorized",
      aria_label: "#{label} not counted: not authorized",
      title: "#{label} could not be counted because the tracker credential was missing or rejected. Check the token."
    }

  defp count_failure_presentation(label, :schema, _reset_at),
    do: %{
      text: "Unreadable response",
      aria_label: "#{label} not counted: unreadable response",
      title: "#{label} could not be counted because the tracker response did not match the expected shape."
    }

  # Aiur's own bound, not a tracker fault — say so, so nobody goes looking at
  # GitHub for a limit we imposed.
  defp count_failure_presentation(label, :incomplete, _reset_at),
    do: %{
      text: "Partial read",
      aria_label: "#{label} not counted: partial read",
      title: "#{label} could not be counted because the read hit Aiur's planning page limit before every member."
    }

  defp count_failure_presentation(label, _failure, _reset_at),
    do: %{
      text: "Unresolved",
      aria_label: "#{label} not counted",
      title: "#{label} could not be counted for this Build Order"
    }

  defp reset_suffix(%DateTime{} = reset_at), do: " until #{format_reset(reset_at)}"
  defp reset_suffix(_reset_at), do: ""

  defp reset_sentence(%DateTime{} = reset_at), do: " It resets at #{format_reset(reset_at)}."
  defp reset_sentence(_reset_at), do: ""

  defp format_reset(%DateTime{} = reset_at) do
    reset_at |> DateTime.truncate(:second) |> Calendar.strftime("%H:%M UTC")
  end

  defp catalog_icon("bolt"), do: "ϟ"
  defp catalog_icon("cube"), do: "◆"
  defp catalog_icon("sparkles"), do: "✦"
  defp catalog_icon("server-stack"), do: "▤"
  defp catalog_icon("rectangle-group"), do: "▦"
  defp catalog_icon(_icon), do: "◈"

  defp catalog_icon_label(icon) when is_binary(icon) and icon != "", do: "Build Order icon: #{icon}"
  defp catalog_icon_label(_icon), do: "Build Order icon"

  defp catalog_path(%RootSummary{identity: %TrackerIdentity{identifier: identifier} = identity}) when is_binary(identifier) do
    if TrackerIdentity.joinable?(identity), do: "/build-orders/#{identifier}"
  end

  defp catalog_path(_entry), do: nil

  defp catalog_notice(%Snapshot{health: %{state: :stale}}),
    do: %{title: "Build Order list", message: "Build Orders are listed below."}

  defp catalog_notice(%Snapshot{health: %{state: :structurally_invalid}}),
    do: %{title: "Catalog validation warning", message: "Showing bounded entries with structural diagnostics."}

  defp catalog_notice(_snapshot), do: nil

  defp catalog_state_title(:loading), do: "Loading Build Orders"
  defp catalog_state_title(:stale), do: "Build Order list is unavailable"
  defp catalog_state_title(:invalid), do: "Build Order list is unreadable"
  defp catalog_state_title(_state), do: "No Build Order list"

  defp catalog_state_message(:loading), do: "Waiting for the first list of Build Orders."
  defp catalog_state_message(:stale), do: "The list of Build Orders is not available right now."
  defp catalog_state_message(:invalid), do: "The list of Build Orders came back unreadable."
  defp catalog_state_message(_state), do: "No readable list of Build Orders is available."

  defp catalog_state_role(:invalid), do: "alert"
  defp catalog_state_role(_state), do: "status"
end
