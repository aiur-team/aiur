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

  ## Five layers

    * **Map** — every resource type as a tile, sized by how many entries it
      holds and coloured by how stale its worst entry is, so a stale region is
      visible without reading any text.
    * **History** — two time-series charts from the sampler's ring: entries
      over time (total, with body, validator-only) and the same totals stacked
      by freshness, so "how up to date" is a band that can be watched growing
      rather than a number to compare.
    * **Usage** — what is spending the API budget, per budget, ranked by points
      with the remainder this daemon did not issue as its own band. The one tool
      for that question, `aiur github-cost`, boots a fresh BEAM under `eval` and
      reads a meter that has never observed anything; this page runs inside the
      daemon and reads the live one, which is why the answer lives here.
    * **Group** — one type's entries: identity, age, writer, what validator and
      body the store holds for each.
    * **Entry** — the full record, with the cached body pretty-printed.

  Each layer is a URL. A deep link to an entry resolves after a restart because
  the identity is the resource's own — `(type, owner, repo, id)` — not a
  position in a list that the next write would invalidate.

  ## History is a live-session feature

  The two charts are fed by `Aiur.GitHub.CacheHistory`, a sampler that reads the
  same ETS table this page reads — never GitHub — on a fixed cadence and keeps a
  bounded ring of recent state. The ring is in-memory and lost on restart, and
  the charts say so, because a chart that drew a flat zero over a span the
  sampler never observed would be the same silent-subset lie the rest of the
  page refuses. When the ring is too new to draw, the page says it is
  collecting.

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

  alias Aiur.GitHub.CacheHistory
  alias Aiur.GitHub.CacheInspector
  alias Aiur.GitHub.CacheInspector.Events
  alias Aiur.GitHub.Quota, as: GitHubQuota
  alias Aiur.GitHub.QuotaHistory
  alias Aiur.GitHub.QuotaUsage

  alias AiurWeb.OperatorControlCenter.{
    AwaitingCommands,
    DashboardShell,
    NavState,
    Overview,
    RouteRegistry
  }

  alias AiurWeb.OperatorControlCenter.GithubCache.{Charts, Styles}

  @highlight_ms 4_000
  @sorts [:age, :identity]
  @bodies [:held, :bodyless]

  @impl true
  def mount(_params, _session, socket) do
    connected = connected?(socket)
    if connected, do: Events.subscribe()
    if connected, do: CacheHistory.subscribe()
    if connected, do: QuotaHistory.subscribe()

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

  # A new history sample landed on the sampler's cadence. The page re-reads the
  # ring (an ETS read) rather than trusting the message's count, matching how
  # every other change here is re-read rather than rendered out of the message.
  def handle_info({:cache_history_sampled, _count}, socket),
    do: {:noreply, assign(socket, :history, history())}

  # The quota sampler's cadence. Re-reads the meter and the ring together, so
  # the ranking table and the chart beside it always describe one instant.
  def handle_info({:quota_history_sampled, _count}, socket) do
    quota = quota_snapshot()

    {:noreply,
     socket
     |> assign(:quota, quota)
     |> assign(:usage, QuotaUsage.sample(quota))
     |> assign(:quota_history, quota_history())}
  end

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
    quota = quota_snapshot()

    socket
    |> assign(:projection, projection)
    |> assign(:quota, quota)
    |> assign(:usage, QuotaUsage.sample(quota))
    |> assign(:history, history())
    |> assign(:quota_history, quota_history())
  end

  # The same provider seam `history/0` uses, for the same reason.
  defp quota_history do
    provider = Application.get_env(:aiur, :github_quota_history_provider, QuotaHistory)
    provider.samples()
  rescue
    _unavailable -> []
  catch
    :exit, _reason -> []
  end

  # The same seam `quota_snapshot/0` uses, for the same reason: the page reads
  # whatever history provider is configured — the sampler in production — and a
  # test can point it at a deterministic double without depending on the global
  # sampler's ring. `CacheHistory.samples/0` itself already fails open to `[]`
  # when the sampler is absent, so the double exists for determinism, not for
  # safety.
  defp history do
    provider = Application.get_env(:aiur, :github_cache_history_provider, CacheHistory)
    provider.samples()
  rescue
    _unavailable -> []
  catch
    :exit, _reason -> []
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
    matched = matching_entries(assigns)

    assigns =
      assigns
      |> assign(:visible, Enum.take(matched, assigns.projection.limit))
      |> assign(:matched, length(matched))
      |> assign(:group_elided, max(length(matched) - assigns.projection.limit, 0))
      |> assign(:group_total, group_total(assigns))
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

        <.trends :if={@projection.available? and is_nil(@group)} history={@history} />

        <.usage_layer :if={is_nil(@group)} usage={@usage} quota_history={@quota_history} />

        <.group_layer
          :if={@projection.available? and not is_nil(@group) and is_nil(@entry_identity)}
          group={@group}
          visible={@visible}
          matched={@matched}
          group_total={@group_total}
          group_elided={@group_elided}
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
          of {@observed_calls} calls the meter attributed this window
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
    # Computed once for the whole map rather than per cell: `weight/2` is called
    # for every tile and the largest group does not change between them.
    assigns = assign(assigns, :largest, assigns.projection.groups |> Enum.map(& &1.count) |> Enum.max(fn -> 1 end))

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
        style={"--ghc-weight: #{weight(group, @largest)}; --ghc-stale: #{group.stale_fraction}"}
      >
        <span class="ghc-cell-count">{group.count}</span>
        <span class="ghc-cell-label">{group.label}</span>
        <span class="ghc-cell-freshness">
          {group.freshness.fresh} fresh · {group.freshness.stale} older · {group.freshness.expired} expired
        </span>
        <span :if={group.bodyless > 0} class="ghc-cell-bodyless">
          {group.bodyless} validator only
        </span>
        <span :if={group.elided > 0} class="ghc-cell-elided">
          {group.shown} of {group.count} drawn
        </span>
      </.link>
    </div>
    """
  end

  # The map layer answers "what is held now"; this answers "how did it get
  # here". Two charts from the sampler's ring: entries over time (total, with
  # body, validator-only) and the same totals stacked by freshness, so a cache
  # that is quietly going stale reads as a growing band rather than a number
  # that has to be compared. Charts only ever draw what the sampler recorded —
  # an empty ring renders a "collecting" note, never a fabricated zero line.
  defp trends(assigns) do
    assigns =
      assigns
      |> assign(:enough?, length(assigns.history) >= 2)
      |> assign(:history_window, history_window(assigns.history))

    ~H"""
    <section class="ghc-trends" data-role="trends" aria-labelledby="ghc-trends-title">
      <div class="ghc-trends-head">
        <h2 id="ghc-trends-title" class="ghc-trends-title">History</h2>
        <p class="ghc-trends-note" data-role="history-window">
          {history_note(@history_window, @enough?)}
        </p>
      </div>

      <div :if={not @enough?} class="ghc-empty" data-role="history-collecting">
        <strong>Collecting cache history.</strong>
        <p>
          The charts draw what the sampler has recorded since this daemon boot. They fill in as
          samples accumulate — nothing is fetched to produce them.
        </p>
      </div>

      <div :if={@enough?} class="ghc-charts">
        <figure class="ghc-chart" data-role="entries-chart">
          <figcaption class="ghc-chart-title">Entries over time</figcaption>
          <div class="ghc-chart-body">{Phoenix.HTML.raw(Charts.entries_over_time(@history))}</div>
          <figcaption class="ghc-chart-legend">
            <span class="ghc-legend-item"><i class="ghc-legend-swatch" style="background:var(--fg)"></i>total</span>
            <span class="ghc-legend-item"><i class="ghc-legend-swatch" style="background:var(--good)"></i>hold a body</span>
            <span class="ghc-legend-item"><i class="ghc-legend-swatch" style="background:var(--attention)"></i>validator only</span>
          </figcaption>
        </figure>

        <figure class="ghc-chart" data-role="freshness-chart">
          <figcaption class="ghc-chart-title">Freshness over time</figcaption>
          <div class="ghc-chart-body">{Phoenix.HTML.raw(Charts.freshness_over_time(@history))}</div>
          <figcaption class="ghc-chart-legend">
            <span class="ghc-legend-item"><i class="ghc-legend-swatch" style="background:var(--good)"></i>fresh</span>
            <span class="ghc-legend-item"><i class="ghc-legend-swatch" style="background:var(--attention)"></i>older</span>
            <span class="ghc-legend-item"><i class="ghc-legend-swatch" style="background:var(--blocking)"></i>expired</span>
            <span class="ghc-legend-item"><i class="ghc-legend-swatch" style="background:var(--faint)"></i>unknown</span>
          </figcaption>
        </figure>
      </div>
    </section>
    """
  end

  # What is spending the API budget, per budget, ranked.
  #
  # This exists because the one tool for the job cannot do it: `aiur
  # github-cost` runs under `eval`, boots a fresh BEAM and calls
  # `Quota.snapshot/0` on a meter that has never observed anything, so it reads
  # an empty meter and prints an empty ranking. The dashboard runs *inside* the
  # daemon and reads the live meter directly, which is what makes this the right
  # surface for the question. Two wrong diagnoses were made in one night against
  # the CLI's blind spot.
  #
  # Three rules the rendering must not break:
  #
  #   * GraphQL and core are never summed. They are separate budgets on separate
  #     windows with separate limits; core sat at 88/5000 while GraphQL hit
  #     0/5000, and one combined figure would have described neither.
  #   * The remainder is a band, not a footnote. On a shared GitHub App
  #     installation most of the bill is spend this daemon never issued, and a
  #     chart showing only the attributed rows would be a confident, ranked,
  #     wrong picture — the exact failure class this page exists to refuse.
  #   * Nothing unobserved is drawn as zero. No meter, no window, and a window
  #     whose reset has passed each say so in words.
  #
  # It renders even when the cache store is absent: the meter is a different
  # process and a budget can be burning while nothing at all is cached.
  defp usage_layer(assigns) do
    assigns = assign(assigns, :budgets, QuotaUsage.budgets(assigns.usage))

    ~H"""
    <section class="ghc-usage" data-role="usage" aria-labelledby="ghc-usage-title">
      <div class="ghc-trends-head">
        <h2 id="ghc-usage-title" class="ghc-trends-title">What is spending the budget</h2>
        <p class="ghc-trends-note" data-role="usage-window">
          Sampled from the quota meter every 30s since this daemon boot — about an hour at most,
          in memory, lost on restart. Reading this page never causes a GitHub request.
        </p>
      </div>

      <div :if={@budgets == []} class="ghc-empty" data-role="usage-unobserved">
        <strong>The quota meter has not observed a rate-limit window yet.</strong>
        <p>
          That is not the same as nothing having been spent. Until the meter reads a window there
          is no measurement to rank, so nothing is drawn — a zero here would be a guess.
        </p>
      </div>

      <article
        :for={{resource, budget} <- @budgets}
        class="ghc-usage-budget"
        data-role="usage-budget"
        data-budget={resource}
      >
        <div class="ghc-usage-head">
          <h3 class="ghc-usage-budget-name">{resource} budget</h3>
          <span class="ghc-usage-window">{window_text(budget.window)}</span>
        </div>

        <div class="ghc-usage-splits">
          <div class={split_class(budget.spend)} data-role="usage-spend">
            <span class="ghc-usage-split-value">{measured(budget.spend)}</span>
            <span class="ghc-usage-split-label">Window spend, per GitHub</span>
          </div>

          <div class="ghc-usage-split" data-role="usage-attributed">
            <span class="ghc-usage-split-value">{budget.attributed}</span>
            <span class="ghc-usage-split-label">Attributed to this daemon</span>
          </div>

          <div
            class={split_class(budget.outside)}
            data-role="usage-outside"
            data-value={budget.outside}
            data-observed-whole-window={to_string(QuotaUsage.observation_complete?(budget))}
          >
            <span class="ghc-usage-split-value">{measured(budget.outside)}</span>
            <span class="ghc-usage-split-label">{outside_split_label(budget)}</span>
          </div>
        </div>

        <p
          :if={not QuotaUsage.observation_complete?(budget)}
          class="ghc-usage-note ghc-usage-note-strong"
          data-role="usage-reach"
        >
          <strong>This remainder is not attributable yet.</strong>
          The meter has been observing since {moment(budget.observed_from)}, but this window opened at
          {moment(budget.window_started_at)} — so anything spent in between, including this daemon's own
          calls from before its last restart, is counted here rather than against a caller. Attribution
          covers the whole window again from {moment(QuotaUsage.attributable_from(budget))}, when the
          window resets.
        </p>

        <p :if={is_nil(budget.spend)} class="ghc-usage-note" data-role="usage-spend-unobserved">
          The credential's window has passed its reset and has not been read since, so
          <code>limit - remaining</code>
          would describe a window that has closed. The ranking below still holds — it is what this
          daemon issued — but how much of the bill it explains cannot be stated right now.
        </p>

        <p :if={budget.direction == :excess} class="ghc-usage-note ghc-usage-note-strong" data-role="usage-excess">
          This daemon attributed more than the window reports spending. Points cannot be counted
          twice, so this is an accounting bug, not a shared credential.
        </p>

        <p :if={budget.estimated?} class="ghc-usage-note" data-role="usage-estimated">
          Some rows are marked <strong>assumed</strong>: the response carried no price and one point
          was charged for the call. Reported rows carry GitHub's own <code>rateLimit.cost</code>.
        </p>

        <.usage_chart series={QuotaUsage.series(@quota_history, resource)} resource={resource} />

        <table class="ghc-usage-table" data-role="usage-table">
          <caption class="ghc-usage-split-label">
            {resource} spend by caller, this window. Share is of the attributed total, not of the bill.
          </caption>
          <thead>
            <tr>
              <th scope="col">Caller</th>
              <th scope="col">Points</th>
              <th scope="col">Calls</th>
              <th scope="col">Points/hr</th>
              <th scope="col">Share of attributed</th>
              <th scope="col">Source</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={caller <- QuotaUsage.ranked_callers(budget)} data-role="usage-caller" data-caller={caller.caller}>
              <td>{caller.caller}</td>
              <td>{caller.points}</td>
              <td>{caller.calls}</td>
              <td>{measured(caller.points_per_hour)}</td>
              <td>{share_text(QuotaUsage.share_of_attributed(caller, budget))}</td>
              <td class={source_class(caller.estimated?)}>{source_text(caller.estimated?)}</td>
            </tr>

            <tr class="ghc-usage-row-outside" data-role="usage-outside-row">
              <td>{QuotaUsage.outside_label(QuotaUsage.observation_complete?(budget))}</td>
              <td>{measured(budget.outside)}</td>
              <td>unknown</td>
              <td>unknown</td>
              <td>not attributed</td>
              <td class="ghc-usage-source">{outside_source(budget)}</td>
            </tr>
          </tbody>
        </table>

        <p class="ghc-usage-note" data-role="usage-outside-explainer">
          {outside_explainer(budget)}
        </p>
      </article>
    </section>
    """
  end

  # An empty ring and an unobserved window are different facts and get different
  # words. Neither draws an axis: an empty chart reads as a measured flat zero,
  # which against a budget that may be exhausted is the worst thing this page
  # could say.
  defp usage_chart(assigns) do
    assigns = assign(assigns, :attributed, QuotaUsage.attributed_only(assigns.series))

    ~H"""
    <div :if={is_nil(@series)} class="ghc-empty" data-role="usage-collecting">
      <strong>Collecting {@resource} spend history.</strong>
      <p>
        The chart needs two samples where the credential's own window was observed. It fills in on
        the sampler's cadence — nothing is fetched to produce it.
      </p>
    </div>

    <div :if={not is_nil(@series)} class="ghc-charts">
      <figure class="ghc-chart" data-role="usage-chart" data-budget={@resource}>
        <figcaption class="ghc-chart-title">The whole {@resource} bill</figcaption>
        <div class="ghc-chart-body">{Phoenix.HTML.raw(Charts.spend_over_time(@series))}</div>
        <figcaption class="ghc-chart-legend">
          <span :for={band <- @series.bands} class="ghc-legend-item" data-band={band.key}>
            <i class="ghc-legend-swatch" style={"background:#{Charts.band_color(band)}"}></i>{band.label}
          </span>
        </figcaption>
        <figcaption class="ghc-usage-note">
          Stacks to the credential's own spend, so the height is the bill and the caller bands are
          the share of it this daemon can explain.
        </figcaption>
      </figure>

      <figure :if={not is_nil(@attributed)} class="ghc-chart" data-role="usage-chart-attributed" data-budget={@resource}>
        <figcaption class="ghc-chart-title">Only what this daemon issued</figcaption>
        <div class="ghc-chart-body">{Phoenix.HTML.raw(Charts.spend_over_time(@attributed))}</div>
        <figcaption class="ghc-chart-legend">
          <span :for={band <- @attributed.bands} class="ghc-legend-item" data-band={band.key}>
            <i class="ghc-legend-swatch" style={"background:#{Charts.band_color(band)}"}></i>{band.label}
          </span>
        </figcaption>
        <figcaption class="ghc-usage-note">
          The same callers rescaled to their own total, because on the chart beside it they are a
          sliver. This is <strong>not</strong> the bill — read the height there, the ranking here.
        </figcaption>
      </figure>
    </div>

    <div :if={not is_nil(@series)}>
      <p :if={@series.dropped > 0} class="ghc-usage-note" data-role="usage-dropped">
        {@series.dropped} earlier
        {if @series.dropped == 1, do: "sample is", else: "samples are"} not drawn: the credential's
        window was not observed then, so the remainder over that span was never measured.
      </p>
    </div>
    """
  end

  # Naming another consumer is a claim, and it needs the meter to have been
  # running when the window opened. Short of that the label says only what is
  # true — this daemon did not see the spend — and leaves who made it open.
  defp outside_split_label(budget) do
    if QuotaUsage.observation_complete?(budget),
      do: "Not issued by this daemon",
      else: "Spend this daemon did not observe"
  end

  # "shared credential" names a cause, and naming a cause needs the same
  # evidence as naming a consumer.
  defp outside_source(budget) do
    if QuotaUsage.observation_complete?(budget), do: "shared credential", else: "outside the meter's reach"
  end

  # Whole seconds. The meter's boot carries microseconds and the window's edges
  # do not, and three timestamps in one sentence should be comparable at a
  # glance rather than differ in precision for no reason the reader can see.
  defp moment(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  defp moment(_absent), do: "an unknown time"

  defp outside_explainer(budget) do
    if QuotaUsage.observation_complete?(budget) do
      "The rows are calls this daemon issued and priced. The last row is the rest of the bill — " <>
        "other consumers on the same GitHub App installation. It is spend, not an error."
    else
      "The rows are calls this daemon issued and priced. The last row is everything else the window " <>
        "was billed for. It is not a claim about another consumer: the meter's attribution is held in " <>
        "memory and does not survive a restart, while GitHub keeps counting across one, so this daemon's " <>
        "own calls from before its last restart are in there too."
    end
  end

  # Never an em-dash standing in for a number. An absent figure says why it is
  # absent, so it can never be read as a measured zero.
  defp measured(value) when is_integer(value), do: value
  defp measured(value) when is_float(value), do: value
  defp measured(_value), do: "not measured"

  defp split_class(value) when is_integer(value) or is_float(value), do: "ghc-usage-split"
  defp split_class(_value), do: "ghc-usage-split ghc-usage-unmeasured"

  defp source_class(true), do: "ghc-usage-source ghc-usage-source-assumed"
  defp source_class(_estimated?), do: "ghc-usage-source"

  defp source_text(true), do: "assumed"
  defp source_text(_estimated?), do: "reported"

  defp share_text(share) when is_float(share), do: "#{Float.round(share * 100, 1)}%"
  defp share_text(_share), do: "not measured"

  defp window_text(%{limit: limit, remaining: remaining} = window) when is_integer(limit) and is_integer(remaining),
    do: "#{remaining} of #{limit} remaining · resets #{value(Map.get(window, :reset_at))}"

  defp window_text(_window), do: "window not observed"

  defp history_window([]), do: {0, 0}
  defp history_window(history), do: {hd(history).t_ms, List.last(history).t_ms}

  defp history_note({t0, t1}, true), do: "Last #{fmt_window(t1 - t0)} — sampled every 30s since this daemon boot."
  defp history_note(_window, _enough?), do: "Sampled from the cache since this daemon boot."

  defp fmt_window(ms) do
    minutes = div(round(ms / 1000), 60)
    hours = div(minutes, 60)
    remainder = rem(minutes, 60)

    cond do
      hours > 0 and remainder > 0 -> "#{hours}h #{remainder}m"
      hours > 0 -> "#{hours}h"
      true -> "#{minutes}m"
    end
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
        Showing {length(@visible)} of {@matched} matching {@group} entries, out of
        {@group_total} this type holds and {@projection.total} in the whole cache.
        <span :if={@group_elided > 0} class="ghc-elided" data-role="elided">
          {@group_elided} matching entries were not drawn — this page renders at most
          {@projection.limit} rows per resource type.
        </span>
        <span :if={@projection.elided > 0} class="ghc-elided" data-role="ceiling-elided">
          {@projection.elided} entries were not classified at all — the inspector reads at most
          {@projection.ceiling} of them per pass.
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
        No cached entry of this type matches these filters. Clearing them shows the
        {@group_total} entries the cache holds for it.
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
          {freshness_label(level)}
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
  #
  # The row cap is applied per resource type rather than across the store. One
  # global slice of a list ordered by type name gives an alphabetically-late
  # type zero rows while its map tile still advertises a full count — and the
  # empty group page then says "no cached entry matches these filters", which
  # would be false.
  defp matching_entries(%{projection: projection, group: group} = assigns) when not is_nil(group) do
    projection.entries
    |> Enum.filter(&(to_string(&1.resource_type) == group))
    |> filter_search(assigns.search)
    |> filter_freshness(assigns.freshness)
    |> filter_writer(assigns.writer)
    |> filter_body(assigns.body)
    |> sort_entries(assigns.sort)
  end

  defp matching_entries(_assigns), do: []

  defp group_total(%{projection: projection, group: group}) when not is_nil(group) do
    Enum.count(projection.entries, &(to_string(&1.resource_type) == group))
  end

  defp group_total(_assigns), do: 0

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
      # Only `sort` has a default worth omitting from the URL. Rejecting the
      # literal `"age"` across every key — as this once did — silently threw
      # away a search for the word "age".
      |> Enum.reject(fn {key, value} -> value in [nil, ""] or (key == "sort" and value == "age") end)
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

  defp freshness_label(:stale), do: "older"
  defp freshness_label(level), do: to_string(level)

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

  defp weight(group, largest) do
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

  # Redaction happens here, for the one entry on screen, rather than for every
  # entry on every re-render. See `Aiur.GitHub.CacheInspector.Entry.payload/1`.
  defp payload_text(%{bodyless?: true}),
    do: "No body is cached for this entry — only a validator. A reader must fetch unconditionally."

  defp payload_text(entry) do
    case CacheInspector.Entry.payload(entry) do
      nil -> "No body is cached for this entry."
      payload when is_binary(payload) -> payload
      payload -> encode(payload)
    end
  end

  defp encode(payload) do
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
