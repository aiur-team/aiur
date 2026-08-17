defmodule AiurWeb.GithubCacheLive do
  @moduledoc """
  The GitHub state cache, live and strictly view-only.

  This page is the proof that the cache works. Its central claim is that opening
  it, focusing it and holding it open consumes **zero** primary rate limit, and
  that claim is only worth making because the page is structurally unable to
  break it: every read goes to `Aiur.GitHub.CacheInspector`, whose source
  enumerates an ETS table and has no client, no token and no transport within
  reach.

  So there is no invalidate, no eviction, no force-refresh and no fetch-now.
  Each is one line of code and each would make the page unable to demonstrate
  the property it exists to demonstrate. The absence is the feature.

  ## Three layers

    * **Map** — every resource type as a tile, sized by how many entries it
      holds and coloured by how stale its worst entry is, so a stale region is
      visible without reading any text.
    * **Group** — one type's entries: identity, age, writer, whether a validator
      is held.
    * **Entry** — the full record, with the cached payload pretty-printed.

  Each layer is a URL. A deep link to an entry resolves after a restart because
  the identity is the resource's own — `(type, owner, repo, id)` — not a
  position in a list that the next write would invalidate.

  ## Filtering never reads

  Search, freshness, writer and sort all run client-side over the projection
  already in the socket. That is not an optimisation. A filter that re-read the
  store would make typing in a search box cost budget by a longer route, which
  is the same failure as a page that fetches on focus.

  The active filter set is always visible, clearable in one click, and carried
  in the query string, so a filtered view — `?writer=webhook`, watching
  deliveries arrive — can be pasted into a ticket as evidence.

  ## Liveness

  The page subscribes to `Aiur.GitHub.CacheInspector.Events`. A write from any
  writer re-renders it and briefly highlights the row that changed, which is how
  a webhook delivery or an agent mutation can be *watched arriving* rather than
  inferred from a number going up.
  """

  use Phoenix.LiveView, layout: {AiurWeb.Layouts, :app}

  alias Aiur.GitHub.CacheInspector
  alias Aiur.GitHub.CacheInspector.Events
  alias Aiur.GitHub.Quota, as: GitHubQuota

  alias AiurWeb.OperatorControlCenter.{
    AwaitingCommands,
    DashboardShell,
    NavState,
    Overview,
    RouteRegistry
  }

  alias AiurWeb.OperatorControlCenter.GithubCache.Styles

  @highlight_ms 4_000
  @sorts [:age, :writes, :identity]

  @impl true
  def mount(_params, _session, socket) do
    connected = connected?(socket)
    if connected, do: Events.subscribe()

    {:ok,
     socket
     |> NavState.assign_nav()
     |> AwaitingCommands.mount(connected)
     |> assign(:current_route, RouteRegistry.current_route(:github_cache))
     |> assign(:analytics, AiurWeb.Presenter.analytics_navigation())
     |> assign(:tracker_kind, kind(&Aiur.Config.tracker_kind/0, "tracker unavailable"))
     |> assign(:agent_kind, kind(&Aiur.Config.agent_kind/0, "agent unavailable"))
     |> assign(:highlighted, %{})
     |> assign(:search, "")
     |> assign(:freshness, nil)
     |> assign(:writer, nil)
     |> assign(:sort, :age)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:current_route, RouteRegistry.current_route(socket.assigns.live_action))
     |> assign(:group, param(params, "resource_type"))
     |> assign(:entry_identity, param(params, "identity"))
     |> assign(:search, params |> param("q") |> Kernel.||(""))
     |> assign(:freshness, freshness_param(params))
     |> assign(:writer, writer_param(params))
     |> assign(:sort, sort_param(params))}
  end

  # A store write. The projection is re-read from ETS — free, and never a fetch
  # — and the changed row is marked so the arrival is visible rather than merely
  # reflected in a count.
  @impl true
  def handle_info({:github_resource_written, _change} = message, socket) do
    case Events.normalize(message) do
      {:ok, identity} ->
        Process.send_after(self(), {:unhighlight, identity}, @highlight_ms)

        {:noreply,
         socket
         |> update(:highlighted, &Map.put(&1, identity, true))
         |> load()}

      :ignore ->
        {:noreply, load(socket)}
    end
  end

  def handle_info({:unhighlight, identity}, socket),
    do: {:noreply, update(socket, :highlighted, &Map.delete(&1, identity))}

  def handle_info({:decision_changed, _decision_id, _version}, socket),
    do: {:noreply, AwaitingCommands.refresh(socket)}

  def handle_info(:awaiting_commands_tick, socket), do: {:noreply, AwaitingCommands.tick(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("toggle-nav", _params, socket), do: {:noreply, NavState.toggle(socket)}

  @impl true
  def handle_event("restore-nav", %{"collapsed" => collapsed}, socket),
    do: {:noreply, NavState.restore(socket, collapsed)}

  # Every control below is a `push_patch`, never a re-read. The URL is the
  # filter state, so the view is addressable and the back button works, and the
  # projection in the socket is reused untouched.
  def handle_event("search", %{"q" => query}, socket),
    do: {:noreply, patch(socket, %{"q" => query})}

  def handle_event("filter-freshness", %{"freshness" => value}, socket),
    do: {:noreply, patch(socket, %{"freshness" => toggled(socket.assigns.freshness, value)})}

  def handle_event("filter-writer", %{"writer" => value}, socket),
    do: {:noreply, patch(socket, %{"writer" => toggled(socket.assigns.writer, value)})}

  def handle_event("sort", %{"sort" => value}, socket),
    do: {:noreply, patch(socket, %{"sort" => value})}

  def handle_event("clear-filters", _params, socket),
    do: {:noreply, push_patch(socket, to: group_path(socket.assigns.group))}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp load(socket) do
    projection = CacheInspector.project()

    socket
    |> assign(:projection, projection)
    |> assign(:quota, quota_snapshot())
  end

  # The same seam `Aiur.GitHub.Transport` uses to find the meter, so a test can
  # point both at one private meter and assert that holding this page open
  # leaves the rate-limit reading untouched.
  defp quota_snapshot do
    :aiur
    |> Application.get_env(:github_quota_server, GitHubQuota)
    |> GitHubQuota.snapshot()
  rescue
    _unavailable -> %{}
  catch
    :exit, _reason -> %{}
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:visible, visible_entries(assigns))
      |> assign(:active_filters, active_filters(assigns))
      |> assign(:entry, CacheInspector.find(assigns.projection, assigns.entry_identity))

    ~H"""
    <DashboardShell.dashboard_shell
      route={@current_route}
      routes={RouteRegistry.routes(@analytics)}
      title={page_title(@group, @entry_identity)}
      back_path={back_path(@group, @entry_identity)}
      back_label={back_label(@group, @entry_identity)}
      tracker_kind={@tracker_kind}
      agent_kind={@agent_kind}
      nav_collapsed={@nav_collapsed}
      nav_counts={@nav_counts}
    >
      <:banner>
        <Overview.decisions_banner retained_counts={@retained_counts} navigate />
      </:banner>

      {Phoenix.HTML.raw("<style>" <> Styles.css() <> "</style>")}

      <section id="github-cache-page" class="ghc-root" aria-label="GitHub state cache inspector">
        <p class="ghc-readonly" data-role="readonly-notice">
          Read-only. Viewing this page never causes a GitHub request — no refresh, no invalidate,
          no eviction. It renders what the cache already holds and updates when a writer writes.
        </p>

        <.cost_strip quota={@quota} projection={@projection} />

        <div :if={not @projection.available?} class="ghc-empty" data-role="store-unavailable">
          <strong>No cache store is running yet.</strong>
          <p>
            Nothing is cached, which is not the same as nothing having happened. Entries appear
            here as soon as a writer writes one.
          </p>
        </div>

        <.map_layer :if={@projection.available? and is_nil(@group)} projection={@projection} />

        <.group_layer
          :if={@projection.available? and not is_nil(@group) and is_nil(@entry_identity)}
          group={@group}
          visible={@visible}
          projection={@projection}
          search={@search}
          freshness={@freshness}
          writer={@writer}
          sort={@sort}
          active_filters={@active_filters}
          highlighted={@highlighted}
        />

        <.entry_layer
          :if={@projection.available? and not is_nil(@entry_identity)}
          entry={@entry}
          group={@group}
          identity={@entry_identity}
        />
      </section>
    </DashboardShell.dashboard_shell>
    """
  end

  # The headline tile is `Fetches caused by viewing`, and it must read zero.
  # It is derived from the quota meter rather than written as a constant, so a
  # future view path that did fetch would show up here instead of being
  # contradicted by a hard-coded reassurance.
  defp cost_strip(assigns) do
    assigns =
      assigns
      |> assign(:view_fetches, CacheInspector.view_fetches(assigns.quota))
      |> assign(:writers, CacheInspector.writes_by_writer(assigns.projection))
      |> assign(:windows, Map.get(assigns.quota, :windows, %{}))

    ~H"""
    <div class="ghc-cost" aria-label="Cache cost">
      <div class="ghc-tile ghc-tile-headline" data-role="view-fetches" data-value={@view_fetches}>
        <span class="ghc-tile-value">{@view_fetches}</span>
        <span class="ghc-tile-label">Fetches caused by viewing</span>
      </div>

      <div :for={{resource, window} <- @windows} class="ghc-tile" data-role={"window-#{resource}"}>
        <span class="ghc-tile-value">{budget_value(window)}</span>
        <span class="ghc-tile-label">{resource} remaining / limit</span>
        <span class="ghc-tile-note">resets {value(Map.get(window, :reset_at))}</span>
      </div>

      <div class="ghc-tile" data-role="entry-count">
        <span class="ghc-tile-value">{@projection.total}</span>
        <span class="ghc-tile-label">Cached entries</span>
      </div>

      <div class="ghc-tile ghc-tile-wide" data-role="writers">
        <span class="ghc-tile-label">Entries by writer</span>
        <ul class="ghc-writer-list">
          <li :for={{writer, count} <- @writers}>
            <span class="ghc-writer-name">{writer}</span>
            <span class="ghc-writer-count">{count}</span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp map_layer(assigns) do
    ~H"""
    <div class="ghc-map" data-role="map-layer">
      <p :if={@projection.groups == []} class="ghc-empty">The cache holds no entries yet.</p>

      <.link
        :for={group <- @projection.groups}
        patch={group_path(to_string(group.resource_type))}
        class="ghc-cell"
        data-role="map-cell"
        data-resource-type={group.resource_type}
        data-worst={group.worst}
        data-count={group.count}
        style={"--ghc-weight: #{weight(group, @projection)}; --ghc-stale: #{group.stale_fraction}"}
      >
        <span class="ghc-cell-count">{group.count}</span>
        <span class="ghc-cell-label">{group.label}</span>
        <span class="ghc-cell-freshness">
          {group.freshness.fresh} fresh · {group.freshness.stale} stale · {group.freshness.expired} expired
        </span>
      </.link>
    </div>
    """
  end

  defp group_layer(assigns) do
    ~H"""
    <div class="ghc-group" data-role="group-layer" data-resource-type={@group}>
      <.controls
        group={@group}
        search={@search}
        freshness={@freshness}
        writer={@writer}
        sort={@sort}
        active_filters={@active_filters}
      />

      <p class="ghc-count" data-role="result-count">
        Showing {length(@visible)} of {@projection.total} cached entries.
        <span :if={@projection.elided > 0} class="ghc-elided" data-role="elided">
          {@projection.elided} entries were not loaded — the page renders at most {@projection.limit}.
        </span>
      </p>

      <table class="ghc-table">
        <thead>
          <tr>
            <th scope="col">Identity</th>
            <th scope="col">Age</th>
            <th scope="col">Writer</th>
            <th scope="col">Validator</th>
            <th scope="col">Writes</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={entry <- @visible}
            data-role="entry-row"
            data-identity={entry.identity}
            data-freshness={entry.freshness}
            data-writer={entry.writer}
            class={if Map.has_key?(@highlighted, entry.identity), do: "ghc-row ghc-row-changed", else: "ghc-row"}
          >
            <td>
              <.link patch={entry_path(@group, entry.identity)}>{entry.identity}</.link>
            </td>
            <td data-role="age">{age_label(entry)}</td>
            <td>{entry.writer}</td>
            <td>{if entry.validator?, do: "held", else: "none"}</td>
            <td>{entry.writes}</td>
          </tr>
        </tbody>
      </table>

      <p :if={@visible == []} class="ghc-empty" data-role="no-matches">
        No cached entry matches these filters. Clearing them shows everything the cache holds.
      </p>
    </div>
    """
  end

  defp controls(assigns) do
    assigns = assign(assigns, :sorts, @sorts)

    ~H"""
    <div class="ghc-controls" aria-label="Filters">
      <form phx-change="search" phx-submit="search" class="ghc-search">
        <label for="ghc-search-input">Search by identity</label>
        <input
          id="ghc-search-input"
          type="search"
          name="q"
          value={@search}
          autocomplete="off"
          phx-debounce="150"
          placeholder="e.g. 1999"
        />
      </form>

      <div class="ghc-filter-row" role="group" aria-label="Freshness">
        <button
          :for={level <- CacheInspector.freshness_levels()}
          type="button"
          phx-click="filter-freshness"
          phx-value-freshness={level}
          data-role="freshness-filter"
          data-active={to_string(@freshness == level)}
          class={if @freshness == level, do: "ghc-chip ghc-chip-on", else: "ghc-chip"}
        >
          {level}
        </button>
      </div>

      <div class="ghc-filter-row" role="group" aria-label="Writer">
        <button
          :for={writer <- CacheInspector.writers()}
          type="button"
          phx-click="filter-writer"
          phx-value-writer={writer}
          data-role="writer-filter"
          data-active={to_string(@writer == writer)}
          class={if @writer == writer, do: "ghc-chip ghc-chip-on", else: "ghc-chip"}
        >
          {writer}
        </button>
      </div>

      <div class="ghc-filter-row" role="group" aria-label="Sort">
        <button
          :for={sort <- @sorts}
          type="button"
          phx-click="sort"
          phx-value-sort={sort}
          data-role="sort-control"
          data-active={to_string(@sort == sort)}
          class={if @sort == sort, do: "ghc-chip ghc-chip-on", else: "ghc-chip"}
        >
          by {sort}
        </button>
      </div>

      <div :if={@active_filters != []} class="ghc-active" data-role="active-filters">
        <span>Active:</span>
        <span :for={filter <- @active_filters} class="ghc-active-item">{filter}</span>
        <button type="button" phx-click="clear-filters" data-role="clear-filters" class="ghc-clear">
          Clear all
        </button>
      </div>
    </div>
    """
  end

  defp entry_layer(assigns) do
    ~H"""
    <div class="ghc-entry" data-role="entry-layer" data-identity={@identity}>
      <div :if={is_nil(@entry)} class="ghc-empty" data-role="entry-missing">
        <strong>Nothing is cached under {@identity}.</strong>
        <p>
          The link resolved; the cache simply does not hold this resource. Nothing was fetched to
          find that out.
        </p>
      </div>

      <div :if={@entry} class="ghc-record">
        <dl>
          <dt>Resource key</dt>
          <dd data-role="field-key">{@entry.identity}</dd>
          <dt>Fetched at</dt>
          <dd data-role="field-fetched-at">{value(@entry.fetched_at)}</dd>
          <dt>Age</dt>
          <dd>{age_label(@entry)}</dd>
          <dt>Version</dt>
          <dd data-role="field-version">{value(@entry.version)}</dd>
          <dt>ETag</dt>
          <dd data-role="field-etag">{value(@entry.etag)}</dd>
          <dt>Last writer</dt>
          <dd data-role="field-writer">{@entry.writer} ({value(@entry.source)})</dd>
          <dt>Writes</dt>
          <dd>{@entry.writes}</dd>
        </dl>

        <details class="ghc-payload" data-role="payload">
          <summary>Cached payload</summary>
          <pre>{payload_text(@entry.payload)}</pre>
        </details>
      </div>
    </div>
    """
  end

  # Filtering and sorting happen here, over the projection already loaded. No
  # branch of this function can reach the store.
  defp visible_entries(%{projection: projection, group: group} = assigns) when not is_nil(group) do
    projection.entries
    |> Enum.filter(&(to_string(&1.resource_type) == group))
    |> filter_search(assigns.search)
    |> filter_freshness(assigns.freshness)
    |> filter_writer(assigns.writer)
    |> sort_entries(assigns.sort)
  end

  defp visible_entries(_assigns), do: []

  defp filter_search(entries, query) when is_binary(query) and query != "" do
    needle = String.downcase(String.trim(query))

    if needle == "",
      do: entries,
      else: Enum.filter(entries, &String.contains?(CacheInspector.Entry.searchable(&1), needle))
  end

  defp filter_search(entries, _query), do: entries

  defp filter_freshness(entries, nil), do: entries
  defp filter_freshness(entries, level), do: Enum.filter(entries, &(&1.freshness == level))

  defp filter_writer(entries, nil), do: entries
  defp filter_writer(entries, writer), do: Enum.filter(entries, &(&1.writer == writer))

  defp sort_entries(entries, :writes), do: Enum.sort_by(entries, &{-&1.writes, &1.identity})
  defp sort_entries(entries, :identity), do: Enum.sort_by(entries, & &1.identity)
  defp sort_entries(entries, _age), do: Enum.sort_by(entries, &{-(&1.age_ms || 0), &1.identity})

  defp active_filters(assigns) do
    [
      if(assigns.search not in [nil, ""], do: "search: #{assigns.search}"),
      if(assigns.freshness, do: "freshness: #{assigns.freshness}"),
      if(assigns.writer, do: "writer: #{assigns.writer}"),
      if(assigns.sort != :age, do: "sort: #{assigns.sort}")
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp patch(socket, changes) do
    query =
      %{
        "q" => socket.assigns.search,
        "freshness" => socket.assigns.freshness && to_string(socket.assigns.freshness),
        "writer" => socket.assigns.writer && to_string(socket.assigns.writer),
        "sort" => to_string(socket.assigns.sort)
      }
      |> Map.merge(changes)
      |> Enum.reject(fn {_key, value} -> value in [nil, "", "age"] end)
      |> Map.new()

    push_patch(socket, to: group_path(socket.assigns.group, query))
  end

  defp toggled(current, value) do
    if to_string(current) == value, do: nil, else: value
  end

  defp group_path(group, query \\ %{})
  defp group_path(nil, _query), do: "/github-cache"

  defp group_path(group, query) when map_size(query) == 0, do: "/github-cache/#{group}"
  defp group_path(group, query), do: "/github-cache/#{group}?" <> URI.encode_query(query)

  defp entry_path(group, identity), do: "/github-cache/#{group}/#{URI.encode_www_form(identity)}"

  defp page_title(nil, _identity), do: "GitHub cache"
  defp page_title(group, nil), do: "GitHub cache · #{group}"
  defp page_title(_group, identity), do: "GitHub cache · #{identity}"

  defp back_path(nil, _identity), do: nil
  defp back_path(_group, nil), do: group_path(nil)
  defp back_path(group, _identity), do: group_path(group)

  defp back_label(nil, _identity), do: nil
  defp back_label(_group, nil), do: "Back to the cache map"
  defp back_label(_group, _identity), do: "Back to the group"

  defp weight(group, projection) do
    largest = projection.groups |> Enum.map(& &1.count) |> Enum.max(fn -> 1 end)

    Float.round(max(group.count / max(largest, 1), 0.15), 3)
  end

  defp age_label(%{age_ms: nil}), do: "unknown"
  defp age_label(%{age_ms: age_ms}) when age_ms < 1_000, do: "just now"
  defp age_label(%{age_ms: age_ms}) when age_ms < 60_000, do: "#{div(age_ms, 1_000)}s"
  defp age_label(%{age_ms: age_ms}) when age_ms < 3_600_000, do: "#{div(age_ms, 60_000)}m"
  defp age_label(%{age_ms: age_ms}), do: "#{div(age_ms, 3_600_000)}h"

  defp budget_value(window) do
    "#{value(Map.get(window, :remaining))} / #{value(Map.get(window, :limit))}"
  end

  defp payload_text(nil), do: "No payload is cached for this entry."
  defp payload_text(payload) when is_binary(payload), do: payload

  defp payload_text(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, encoded} -> encoded
      _unencodable -> inspect(payload, pretty: true, limit: 200)
    end
  end

  # Never "0" and never "-": an unobserved budget and an exhausted one are
  # different facts, and only one of them needs acting on.
  defp value(nil), do: "unknown"
  defp value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp value(value), do: to_string(value)

  defp param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) and value != "" -> value
      _absent -> nil
    end
  end

  defp freshness_param(params) do
    with value when is_binary(value) <- param(params, "freshness"),
         level when not is_nil(level) <- Enum.find(CacheInspector.freshness_levels(), &(to_string(&1) == value)) do
      level
    else
      _invalid -> nil
    end
  end

  defp writer_param(params) do
    with value when is_binary(value) <- param(params, "writer"),
         writer when not is_nil(writer) <- Enum.find(CacheInspector.writers(), &(to_string(&1) == value)) do
      writer
    else
      _invalid -> nil
    end
  end

  defp sort_param(params) do
    with value when is_binary(value) <- param(params, "sort"),
         sort when not is_nil(sort) <- Enum.find(@sorts, &(to_string(&1) == value)) do
      sort
    else
      _invalid -> :age
    end
  end

  defp kind(fun, fallback) do
    fun.()
  rescue
    _unavailable -> fallback
  catch
    :exit, _reason -> fallback
  end
end
