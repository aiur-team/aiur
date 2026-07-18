defmodule AiurWeb.OperatorControlCenter.BuildOrderCatalog do
  @moduledoc "Catalog surface and explicit catalog-state rendering for Build Order routes."

  use Phoenix.Component

  alias Aiur.BuildOrder.{Catalog, RootSummary}
  alias Aiur.BuildOrder.GraphProjection.Snapshot
  alias Aiur.TrackerIdentity
  alias AiurWeb.BuildOrder.RouteState
  alias AiurWeb.OperatorControlCenter.BuildOrderStatus

  attr(:route_state, :any, required: true)
  attr(:now, :any, required: true)

  @spec build_order_catalog(map()) :: Phoenix.LiveView.Rendered.t()
  def build_order_catalog(assigns) do
    ~H"""
    <section class="bo-surface" aria-labelledby="build-order-catalog-title">
      <header class="bo-page-header">
        <div>
          <p class="section-eyebrow">Repository planning</p>
          <h2 id="build-order-catalog-title">Build Order catalog</h2>
          <p>Select a repository-qualified root. Each entry retains its own structural diagnosis.</p>
        </div>
        <BuildOrderStatus.provider_health snapshot={RouteState.catalog_snapshot(@route_state)} now={@now} />
      </header>

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
      |> assign(:catalog_notice, catalog_notice(snapshot))

    ~H"""
    <div class="bo-catalog-list" role="list">
      <div :if={@catalog_notice} class="bo-state-card" role="status">
        <h3>{@catalog_notice.title}</h3>
        <p>{@catalog_notice.message}</p>
      </div>
      <article :for={entry <- @entries} class="bo-catalog-entry" role="listitem">
        <div>
          <p class="mono">{catalog_identifier(entry)}</p>
          <h3>{entry.title}</h3>
          <p class="bo-catalog-entry-state">{catalog_lifecycle(entry)}</p>
          <ul :if={entry.diagnostics != []} class="bo-layout-card-warnings" aria-label="Catalog entry diagnostics">
            <li :for={diagnostic <- entry.diagnostics}>{diagnostic.text}</li>
          </ul>
        </div>
        <.link :if={catalog_path(entry)} patch={catalog_path(entry)} class="link-pill">Open graph</.link>
        <span :if={is_nil(catalog_path(entry))} class="status-badge">Invalid entry</span>
      </article>
      <div :if={@entries == []} class="bo-state-card">
        <h3>No Build Orders</h3>
        <p>The healthy catalog contains no roots.</p>
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

  defp catalog_identifier(%RootSummary{identity: %TrackerIdentity{identifier: identifier}}), do: "##{identifier}"
  defp catalog_identifier(_entry), do: "Unqualified root"

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

  defp catalog_lifecycle(%RootSummary{lifecycle: %{state: state, state_reason: reason}}) do
    state = state |> to_string() |> String.capitalize()

    if reason in [:none, :unknown],
      do: state,
      else: "#{state} · #{reason |> to_string() |> String.replace("_", " ")}"
  end

  defp catalog_lifecycle(_entry), do: "Lifecycle unavailable"
end
