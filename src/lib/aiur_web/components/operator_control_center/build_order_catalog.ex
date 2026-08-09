defmodule AiurWeb.OperatorControlCenter.BuildOrderCatalog do
  @moduledoc "Catalog surface and explicit catalog-state rendering for Build Order routes."

  use Phoenix.Component

  alias Aiur.BuildOrder.{Catalog, RootSummary}
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

      <table :if={@entries != []} class="bo-catalog-table">
        <thead>
          <tr>
            <th scope="col">Title</th>
            <th scope="col" class="bo-catalog-progress-head">Progress</th>
            <th scope="col" class="bo-catalog-num">Tickets</th>
            <th scope="col" class="bo-catalog-num">Epics</th>
            <th scope="col" class="bo-catalog-num">Waves</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={entry <- @entries} class={if(entry.completed?, do: "bo-catalog-completed", else: "bo-catalog-active")}>
            <td>
              <span class="bo-catalog-icon" aria-label={catalog_icon_label(entry.icon)}>{catalog_icon(entry.icon)}</span>
              <.link :if={catalog_path(entry)} patch={catalog_path(entry)} class="bo-catalog-link">{entry.title}</.link>
              <span :if={is_nil(catalog_path(entry))} class="bo-catalog-invalid">{entry.title}</span>
            </td>
            <td class="bo-catalog-progress-cell">
              <.catalog_progress entry={entry} />
            </td>
            <td class="bo-catalog-num mono num">{count_display(entry.member_count)}</td>
            <td class="bo-catalog-num mono num">{count_display(entry.epic_count)}</td>
            <td class="bo-catalog-num mono num">{count_display(entry.phase_count)}</td>
          </tr>
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

  # Progress has four renderings, and no two of them may look alike. A pack
  # whose completion could not be resolved is the state this surface used to
  # lose: it rendered the same blank as "this provider never reported progress"
  # and it was read as "nothing has happened". It now says so in words.
  defp catalog_progress(%{entry: %RootSummary{progress_resolution: :unresolved}} = assigns) do
    ~H"""
    <span
      class="bo-catalog-progress-unresolved"
      data-progress-state="unresolved"
      role="img"
      aria-label={"Progress unknown: completion could not be resolved for #{unresolved_scope(@entry)}"}
      title={"Completion could not be resolved for #{unresolved_scope(@entry)}. This is not zero progress — it is unknown progress."}
    >
      unknown
    </span>
    """
  end

  defp catalog_progress(%{entry: %RootSummary{progress_resolution: :partial, progress: progress}} = assigns)
       when is_integer(progress) do
    ~H"""
    <div
      class="bo-catalog-progress bo-catalog-progress-partial"
      data-progress-state="partial"
      role="img"
      aria-label={"#{@entry.progress}% complete across #{coverage_text(@entry)}"}
      title={"#{@entry.progress}% of the tickets whose completion resolved. Coverage: #{coverage_text(@entry)}."}
    >
      <span class="bo-catalog-progress-track"><i style={"width:#{@entry.progress}%"}></i></span>
      <span class="bo-catalog-progress-label mono num">{@entry.progress}%</span>
      <span class="bo-catalog-progress-coverage mono num">{coverage_ratio(@entry)}</span>
    </div>
    """
  end

  defp catalog_progress(%{entry: %RootSummary{progress: progress}} = assigns) when is_integer(progress) do
    ~H"""
    <div class="bo-catalog-progress" data-progress-state="resolved" role="img" aria-label={"#{@entry.progress}% complete"}>
      <span class="bo-catalog-progress-track"><i style={"width:#{@entry.progress}%"}></i></span>
      <span class="bo-catalog-progress-label mono num">{@entry.progress}%</span>
    </div>
    """
  end

  # No progress was reported at all — the provider made no completion claim.
  # Distinct from `:unresolved`, which is a claim that resolution was attempted
  # and failed.
  defp catalog_progress(assigns) do
    ~H"""
    <span class="bo-catalog-invalid" data-progress-state="not-reported" title="This provider reports no progress for this Build Order.">
      —
    </span>
    """
  end

  defp coverage_ratio(%RootSummary{progress_resolved_count: resolved, member_count: total})
       when is_integer(resolved) and is_integer(total),
       do: "#{resolved}/#{total}"

  defp coverage_ratio(%RootSummary{progress_resolved_count: resolved}) when is_integer(resolved), do: "#{resolved} resolved"
  defp coverage_ratio(_entry), do: "partial"

  defp coverage_text(%RootSummary{progress_resolved_count: resolved, member_count: total})
       when is_integer(resolved) and is_integer(total),
       do: "#{resolved} of #{total} tickets; #{total - resolved} unresolved"

  defp coverage_text(%RootSummary{progress_resolved_count: resolved}) when is_integer(resolved),
    do: "#{resolved} resolved tickets"

  defp coverage_text(_entry), do: "an unknown share of this Build Order"

  defp unresolved_scope(%RootSummary{member_count: total}) when is_integer(total), do: "any of its #{total} tickets"
  defp unresolved_scope(_entry), do: "any of its tickets"

  defp count_display(count) when is_integer(count), do: Integer.to_string(count)
  defp count_display(_count), do: "—"

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
    do: %{title: "Stale catalog", message: "Showing the last-known-good catalog while refresh is degraded."}

  defp catalog_notice(%Snapshot{health: %{state: :structurally_invalid}}),
    do: %{title: "Catalog validation warning", message: "Showing bounded entries with structural diagnostics."}

  defp catalog_notice(_snapshot), do: nil

  defp catalog_state_title(:loading), do: "Loading Build Order catalog"
  defp catalog_state_title(:stale), do: "Catalog is stale"
  defp catalog_state_title(:invalid), do: "Catalog is structurally invalid"
  defp catalog_state_title(_state), do: "Catalog unavailable"

  defp catalog_state_message(:loading), do: "Waiting for the first validated repository catalog snapshot."
  defp catalog_state_message(:stale), do: "The provider is stale and no last-known-good catalog is available."
  defp catalog_state_message(:invalid), do: "The provider response failed structural validation."
  defp catalog_state_message(_state), do: "No validated catalog snapshot is available."

  defp catalog_state_role(:invalid), do: "alert"
  defp catalog_state_role(_state), do: "status"
end
