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
    * **Group** — one type's entries: identity, age, writer, what validator and
      body the store holds for each.
    * **Entry** — the full record, with the cached body pretty-printed.

  Each layer is a URL. A deep link to an entry resolves after a restart because
  the identity is the resource's own — `(type, owner, repo, id)` — not a
  position in a list that the next write would invalidate.

  ## Validator held, body absent, is shown as its own thing

  The most useful distinction this page makes is between an entry that can serve
  a reader and one that only holds an ETag. `Aiur.GitHub.ResourceStore.drop_data/1`
  produces the second on purpose, and a reader that treats it as a hit sends the
  validator, gets a `304`, and receives no data — a call paid for that answers
  nothing. Rendering both as "cached" would hide exactly the thing an operator
  opens this page to find, so bodyless entries carry their own column, their own
  filter, their own row marking and their own count in the headline strip.

  ## Filtering never reads

  Search, freshness, writer, body and sort all run over the projection already
  in the socket. That is not an optimisation. A filter that re-read the store
  would make typing in a search box cost budget by a longer route, which is the
  same failure as a page that fetches on focus.

  The active filter set is always visible, clearable in one click, and carried
  in the query string, so a filtered view — `?writer=webhook`, watching
  deliveries arrive — can be pasted into a ticket as evidence.

  ## Liveness

  The page subscribes to `Aiur.GitHub.CacheInspector.Events`, which is the
  store's own change channel. A write from any writer re-reads the projection
  from ETS and briefly highlights the row that changed, which is how a webhook
  delivery or an agent mutation can be *watched arriving* rather than inferred
  from a number going up. The event never carries the body, so the re-read is
  not an optimisation to remove later — it is the contract.
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
  @sorts [:age, :identity]
  @bodies [:held, :bodyless]

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
     |> assign(:group, nil)
     |> assign(:entry_identity, nil)
     |> assign(:search, "")
     |> assign(:freshness, nil)
     |> assign(:writer, nil)
     |> assign(:body, nil)
     |> assign(:sort, :age)
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:current_route, RouteRegistry.current_route(socket.assigns.live_action))
     |> assign(:group, param(params, "resource_type"))
     |> assign(:entry_identity, identity_param(params))
     |> assign(:search, params |> param("q") |> Kernel.||(""))
     |> assign(:freshness, freshness_param(params))
     |> assign(:writer, writer_param(params))
     |> assign(:body, body_param(params))
     |> assign(:sort, sort_param(params))}
  end

  # A store write. The projection is re-read from ETS — free, and never a fetch
  # — and the changed row is marked so the arrival is visible rather than merely
  # reflected in a count. The change event deliberately carries no body, which
  # is why this re-reads rather than rendering out of the message.
  @impl true
  def handle_info({:github_resource_changed, _change} = message, socket) do
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

  def handle_event("filter-body", %{"body" => value}, socket),
    do: {:noreply, patch(socket, %{"body" => toggled(socket.assigns.body, value)})}

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
          body={@body}
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

  # The headline tile is `Fetches caused by viewing`, and it must read zero. It
  # is derived from the quota meter rather than written as a constant, so a
  # future view path that did fetch would show up here instead of being
  # contradicted by a hard-coded reassurance. The note beside it prints how many
  # calls the meter attributed in total, because a zero from a meter that has
  # observed nothing is not the same fact as a zero from a busy one.
  defp cost_strip(assigns) do
    assigns =
      assigns
      |> assign(:view_fetches, CacheInspector.view_fetches(assigns.quota))
      |> assign(:observed_calls, CacheInspector.observed_calls(assigns.quota))
      |> assign(:writers, CacheInspector.writes_by_writer(assigns.projection))
      |> assign(:windows, Map.get(assigns.quota, :windows, %{}))

    ~H"""
    <div class="ghc-cost" aria-label="Cache cost">
      <div class="ghc-tile ghc-tile-headline" data-role="view-fetches" data-value={@view_fetches}>
        <span class="ghc-tile-value">{@view_fetches}</span>
        <span class="ghc-tile-label">Fetches caused by viewing</span>
        <span class="ghc-tile-note" data-role="view-fetches-context">
          of {@observed_calls} calls the meter attributed
        </span>
      </div>

      <div :for={{resource, window} <- @windows} class="ghc-tile" data-role={"window-#{resource}"}>
        <span class="ghc-tile-value">{budget_value(window)}</span>
        <span class="ghc-tile-label">{resource} remaining / limit</span>
        <span class="ghc-tile-note">resets {value(Map.get(window, :reset_at))}</span>
      </div>

      <div class="ghc-tile" data-role="entry-count">
        <span class="ghc-tile-value">{@projection.total}</span>
        <span class="ghc-tile-label">Cached entries</span>
        <span class="ghc-tile-note">{@projection.with_body} hold a body</span>
      </div>

      <div class="ghc-tile" data-role="bodyless-count" data-value={@projection.bodyless}>
        <span class="ghc-tile-value">{@projection.bodyless}</span>
        <span class="ghc-tile-label">Validator only, no body</span>
        <span class="ghc-tile-note">
          A read of one of these sends the ETag and gets a 304 with no data — it costs a call and
          returns nothing.
        </span>
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
        data-bodyless={group.bodyless}
        style={"--ghc-weight: #{weight(group, @projection)}; --ghc-stale: #{group.stale_fraction}"}
      >
        <span class="ghc-cell-count">{group.count}</span>
        <span class="ghc-cell-label">{group.label}</span>
        <span class="ghc-cell-freshness">
          {group.freshness.fresh} fresh · {group.freshness.stale} stale · {group.freshness.expired} expired
        </span>
        <span :if={group.bodyless > 0} class="ghc-cell-bodyless">
          {group.bodyless} validator only
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
        body={@body}
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
            <th scope="col">Body</th>
            <th scope="col">Version / data version</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={entry <- @visible}
            data-role="entry-row"
            data-identity={entry.identity}
            data-freshness={entry.freshness}
            data-writer={entry.writer}
            data-bodyless={to_string(entry.bodyless?)}
            class={row_class(entry, @highlighted)}
          >
            <td>
              <.link patch={entry_path(@group, entry.identity)}>{entry.identity}</.link>
            </td>
            <td data-role="age">{age_label(entry)}</td>
            <td>{entry.writer}</td>
            <td>{if entry.validator?, do: "held", else: "none"}</td>
            <td data-role="body">{body_label(entry)}</td>
            <td>{value(entry.version)} / {value(entry.data_version)}</td>
          </tr>
        </tbody>
      </table>

      <p :if={@visible == []} class="ghc-empty" data-role="no-matches">
        No cached entry matches these filters. Clearing them shows everything the cache holds.
      </p>
    </div>
    """
  end

  # Controls in the order the design asks for: identity first, because an
  # operator arrives here knowing which resource they are asking about; then
  # freshness, which is the next question they ask about it; then which writer
  # deposited it. Body state comes last because it is a property of the entry
  # rather than a way of finding one — it is called out in the table and the
  # headline strip regardless of whether this filter is touched.
  defp controls(assigns) do
    assigns =
      assigns
      |> assign(:sorts, @sorts)
      |> assign(:bodies, @bodies)

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
          class={chip_class(@freshness == level)}
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
          class={chip_class(@writer == writer)}
        >
          {writer}
        </button>
      </div>

      <div class="ghc-filter-row" role="group" aria-label="Body">
        <button
          :for={body <- @bodies}
          type="button"
          phx-click="filter-body"
          phx-value-body={body}
          data-role="body-filter"
          data-active={to_string(@body == body)}
          class={chip_class(@body == body)}
        >
          {body_filter_label(body)}
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
          class={chip_class(@sort == sort)}
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
        <p :if={@entry && @entry.bodyless?} class="ghc-warn" data-role="bodyless-warning">
          <strong>Validator held, body absent.</strong>
          This entry cannot answer a reader. Sending its ETag returns a 304 with no data, so a
          consumer that treats it as a hit spends a call and gets nothing — it has to re-read
          unconditionally instead. The fetch time below is when the body it no longer holds was
          recorded, so read the age as history rather than as freshness.
        </p>

        <dl>
          <dt>Resource key</dt>
          <dd data-role="field-key">{@entry.identity}</dd>
          <dt>Resource type</dt>
          <dd data-role="field-type">{@entry.resource_type}</dd>
          <dt>Body held</dt>
          <dd data-role="field-body">{body_label(@entry)}</dd>
          <dt>Fetched at</dt>
          <dd data-role="field-fetched-at">{value(@entry.fetched_at)}</dd>
          <dt>Age</dt>
          <dd>{age_label(@entry)}</dd>
          <dt>Processed version</dt>
          <dd data-role="field-version">{value(@entry.version)}</dd>
          <dt>Body version</dt>
          <dd data-role="field-data-version">{value(@entry.data_version)}</dd>
          <dt>ETag</dt>
          <dd data-role="field-etag">{value(@entry.etag)}</dd>
          <dt>Last writer</dt>
          <dd data-role="field-writer">{@entry.writer} ({value(@entry.source)})</dd>
          <dt>Last recorded</dt>
          <dd data-role="field-recorded-at">{value(@entry.recorded_at)}</dd>
        </dl>

        <details class="ghc-payload" data-role="payload">
          <summary>Cached body</summary>
          <pre>{payload_text(@entry)}</pre>
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
    |> filter_body(assigns.body)
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

  defp filter_body(entries, :held), do: Enum.filter(entries, & &1.body?)
  defp filter_body(entries, :bodyless), do: Enum.filter(entries, & &1.bodyless?)
  defp filter_body(entries, _all), do: entries

  defp sort_entries(entries, :identity), do: Enum.sort_by(entries, & &1.identity)
  defp sort_entries(entries, _age), do: Enum.sort_by(entries, &{-(&1.age_ms || 0), &1.identity})

  defp active_filters(assigns) do
    [
      if(assigns.search not in [nil, ""], do: "search: #{assigns.search}"),
      if(assigns.freshness, do: "freshness: #{assigns.freshness}"),
      if(assigns.writer, do: "writer: #{assigns.writer}"),
      if(assigns.body, do: "body: #{assigns.body}"),
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
        "body" => socket.assigns.body && to_string(socket.assigns.body),
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

  defp row_class(entry, highlighted) do
    [
      "ghc-row",
      if(entry.bodyless?, do: "ghc-row-bodyless"),
      if(Map.has_key?(highlighted, entry.identity), do: "ghc-row-changed")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp chip_class(true), do: "ghc-chip ghc-chip-on"
  defp chip_class(_inactive), do: "ghc-chip"

  defp body_filter_label(:held), do: "body held"
  defp body_filter_label(:bodyless), do: "validator only"

  # Never just "none". An entry with a validator and no body reads as a hit to
  # anybody skimming, and it is the opposite of one.
  defp body_label(%{body?: true}), do: "held"
  defp body_label(%{bodyless?: true}), do: "none — validator only"
  defp body_label(_entry), do: "none"

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

  defp payload_text(%{bodyless?: true}),
    do: "No body is cached for this entry — only a validator. A reader must fetch unconditionally."

  defp payload_text(%{payload: nil}), do: "No body is cached for this entry."
  defp payload_text(%{payload: payload}) when is_binary(payload), do: payload

  defp payload_text(%{payload: payload}) do
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

  # The identity arrives URL-encoded from `entry_path/2`. Phoenix decodes the
  # path segment for us, so this only guards the empty case; decoding again here
  # would corrupt an identity that legitimately contains a `+`.
  defp identity_param(params), do: param(params, "identity")

  defp freshness_param(params), do: enum_param(params, "freshness", CacheInspector.freshness_levels(), nil)
  defp writer_param(params), do: enum_param(params, "writer", CacheInspector.writers(), nil)
  defp body_param(params), do: enum_param(params, "body", @bodies, nil)
  defp sort_param(params), do: enum_param(params, "sort", @sorts, :age)

  defp enum_param(params, key, allowed, fallback) do
    with value when is_binary(value) <- param(params, key),
         found when not is_nil(found) <- Enum.find(allowed, &(to_string(&1) == value)) do
      found
    else
      _invalid -> fallback
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
