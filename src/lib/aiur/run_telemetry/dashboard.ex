defmodule Aiur.RunTelemetry.Dashboard do
  @moduledoc """
  Generates the canonical, backend-agnostic telemetry dashboard artifact.

  The result is one portable HTML file: its styles, scripts, normalized report
  data, charts, accessible tables, and operational notes are all inline. It
  performs no browser-side network requests.
  """

  alias Aiur.RunTelemetry.Dashboard.Assets
  alias Aiur.RunTelemetry.{Dataset, GitHubEnricher, Lifecycle}

  @doc "Builds the dataset and writes a self-contained HTML dashboard."
  @spec generate(Path.t() | [Path.t()], Path.t(), keyword()) ::
          {:ok, %{output: Path.t(), dataset: map()}} | {:error, term()}
  def generate(inputs, output, opts \\ []) when is_binary(output) and is_list(opts) do
    output = Path.expand(output)

    with {:ok, %{dataset: dataset, html: html}} <- render_inputs(inputs, opts),
         :ok <- File.mkdir_p(Path.dirname(output)),
         :ok <- File.write(output, html) do
      {:ok, %{output: output, dataset: dataset}}
    else
      {:error, _reason} = error -> error
    end
  rescue
    error -> {:error, {:dashboard_generation_failed, Lifecycle.reason_class(error)}}
  end

  @doc "Builds current telemetry inputs and renders the canonical HTML without writing a file."
  @spec render_inputs(Path.t() | [Path.t()], keyword()) ::
          {:ok, %{html: String.t(), dataset: map()}} | {:error, term()}
  def render_inputs(inputs, opts \\ []) when is_list(opts) do
    with {:ok, initial} <- Dataset.build(inputs, opts),
         {:ok, dataset} <- enrich_dataset(inputs, initial, opts) do
      {:ok, %{html: render(dataset, opts), dataset: dataset}}
    end
  rescue
    error -> {:error, {:dashboard_generation_failed, Lifecycle.reason_class(error)}}
  end

  @doc "Renders an already-reduced dataset as a self-contained HTML document."
  @spec render(map(), keyword()) :: String.t()
  def render(dataset, opts \\ []) when is_map(dataset) and is_list(opts) do
    generated_at = Keyword.get(opts, :generated_at, DateTime.utc_now())
    json = dataset |> dashboard_payload(generated_at) |> Jason.encode!() |> script_safe_json()

    [
      document_start(),
      "<style>",
      Assets.styles(),
      "</style></head><body>",
      body(),
      "<script id=\"aiur-data\" type=\"application/json\">",
      json,
      "</script><script>",
      Assets.javascript(),
      "</script></body></html>"
    ]
    |> IO.iodata_to_binary()
  end

  defp enrich_dataset(inputs, initial, opts) do
    case Keyword.get(opts, :repo) || Keyword.get(opts, :github_repo) do
      repo when is_binary(repo) and repo != "" ->
        enricher = Keyword.get(opts, :github_enricher, &GitHubEnricher.enrich/3)
        enrichment = enricher.(repo, Map.keys(initial.tickets), opts)
        existing_events = Keyword.get(opts, :github_events, [])

        case Dataset.build(inputs, Keyword.put(opts, :github_events, existing_events ++ enrichment.events)) do
          {:ok, dataset} -> {:ok, %{dataset | warnings: dataset.warnings ++ enrichment.warnings}}
          {:error, _reason} = error -> error
        end

      _other ->
        {:ok, initial}
    end
  end

  defp dashboard_payload(dataset, generated_at) do
    %{
      generated_at: timestamp(generated_at),
      provenance: Map.get(dataset, :provenance, %{}),
      restarts: Enum.map(Map.get(dataset, :restarts, []), &restart_payload/1),
      actors: Map.get(dataset, :actors, %{}),
      tickets: dataset |> Map.get(:tickets, %{}) |> ticket_payloads(),
      findings: Map.get(dataset, :findings, []),
      warnings: Map.get(dataset, :warnings, [])
    }
    |> json_value()
  end

  defp restart_payload(restart) do
    %{
      boot_id: Map.get(restart, :boot_id),
      timestamp: Map.get(restart, :timestamp_iso),
      existing_records: get_in(restart, [:attributes, "existing_records"])
    }
  end

  defp ticket_payloads(tickets) do
    Map.new(tickets, fn {ticket, data} ->
      events = Enum.map(Map.get(data, :events, []), &Map.delete(&1, :timestamp_dt))
      {ticket, %{data | events: events}}
    end)
  end

  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp timestamp(value) when is_binary(value), do: value
  defp timestamp(_value), do: DateTime.utc_now() |> DateTime.to_iso8601()

  defp json_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_value(%Date{} = value), do: Date.to_iso8601(value)

  defp json_value(%{__struct__: _module} = value),
    do: value |> Map.from_struct() |> json_value()

  defp json_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), json_value(nested)} end)
  end

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&json_value/1)
  defp json_value(value) when is_boolean(value) or is_nil(value), do: value
  defp json_value(value) when is_atom(value), do: Atom.to_string(value)
  defp json_value(value) when is_binary(value) or is_number(value), do: value
  defp json_value(_value), do: "unavailable"

  defp script_safe_json(json) do
    json
    |> String.replace("<", "\\u003C")
    |> String.replace(">", "\\u003E")
    |> String.replace("&", "\\u0026")
    |> String.replace("\u2028", "\\u2028")
    |> String.replace("\u2029", "\\u2029")
  end

  defp document_start do
    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <meta name="color-scheme" content="light">
      <title>Aiur run telemetry</title>
    """
  end

  defp body do
    """
    <a class="skip-link" href="#run-evidence">Skip to run evidence</a>
    <header class="hero">
      <div class="hero-copy">
        <p class="eyebrow"><span class="signal" aria-hidden="true"></span>Aiur / debug telemetry</p>
        <h1>Run evidence, without the blind spots.</h1>
        <p class="lede">Daemon-recorded resource and lifecycle evidence, reduced into one durable, offline artifact.</p>
        <p class="generated">Generated <time id="generated-at">—</time></p>
      </div>
      <dl class="hero-stats" id="hero-stats" aria-label="Report summary"></dl>
    </header>
    <main>
      <section id="run-evidence" class="panel evidence-panel" aria-labelledby="run-evidence-title">
        <div class="section-heading">
          <div><p class="kicker">01 / provenance</p><h2 id="run-evidence-title">Run evidence</h2></div>
          <p>Inputs, daemon restarts, and recoverable parsing gaps.</p>
        </div>
        <div class="evidence-grid">
          <article class="subpanel"><h3>Source set</h3><dl id="provenance-list" class="facts"></dl></article>
          <article class="subpanel"><h3>Restart markers</h3><ol id="restart-list" class="event-list"></ol></article>
          <article class="subpanel warning-panel"><h3>Warnings</h3><ul id="warning-list" class="warning-list"></ul></article>
        </div>
      </section>

      <section id="review-findings" class="panel" aria-labelledby="review-findings-title">
        <div class="section-heading">
          <div><p class="kicker">02 / listener integrity</p><h2 id="review-findings-title">Review wakeup findings</h2></div>
          <p>Broken pause → resume paths stay visible until real rework and resume events arrive.</p>
        </div>
        <div id="finding-summary" class="finding-summary" aria-live="polite"></div>
        <div id="finding-list" class="finding-list"></div>
      </section>

      <section id="actor-timeline" class="panel" aria-labelledby="actor-timeline-title">
        <div class="section-heading">
          <div><p class="kicker">03 / resource stream</p><h2 id="actor-timeline-title">Per-actor timeline</h2></div>
          <p>Compare daemon, Executor, and ticket process trees on one clock.</p>
        </div>
        <div class="controls actor-controls">
          <label>Metric<select id="resource-metric"></select></label>
          <fieldset><legend>Actors</legend><div id="actor-filters" class="check-row"></div></fieldset>
        </div>
        <p id="actor-state" class="empty-state" hidden></p>
        <div class="chart-viewport" tabindex="0" aria-label="Scrollable per-actor resource chart">
          <svg id="actor-chart" class="chart" role="img" aria-labelledby="actor-chart-title actor-chart-description">
            <title id="actor-chart-title">Per-actor resource timeline</title>
            <desc id="actor-chart-description">Focus a point to read its exact actor, time, and value.</desc>
          </svg>
        </div>
        <output id="actor-detail" class="focus-detail" aria-live="polite">Focus or hover a sample for exact values.</output>
        <details class="data-table"><summary>Accessible actor sample table</summary>
          <div class="table-actions">
            <span id="actor-table-count" class="result-count" role="status" aria-live="polite"></span>
            <button id="actor-table-more" type="button" aria-controls="actor-table-body" hidden>Show more samples</button>
          </div>
          <div class="table-scroll"><table id="actor-table"><caption>Actor resource samples for the selected metric</caption><thead><tr><th>Time</th><th>Actor</th><th>Availability</th><th>Value</th><th>Boot</th></tr></thead><tbody id="actor-table-body"></tbody></table></div>
        </details>
      </section>

      <section id="fleet-pressure" class="panel" aria-labelledby="fleet-pressure-title">
        <div class="section-heading">
          <div><p class="kicker">04 / whole-host pressure</p><h2 id="fleet-pressure-title">Fleet-wide build pressure</h2></div>
          <p>Exact occupied-agent and build-gate evidence. Missing or degraded observations remain gaps, never zeroes.</p>
        </div>
        <div class="phase-legend" aria-label="Fleet pressure source states"><span>Current</span><span>Stale fleet</span><span>Degraded build</span><span>Partial</span><span>Empty</span></div>
        <p id="pressure-state" class="empty-state" hidden></p>
        <div class="chart-viewport" tabindex="0" aria-label="Scrollable whole-host fleet pressure chart">
          <svg id="pressure-chart" class="chart" role="img" aria-label="Fleet-wide occupied agents, build depth, and oldest wait"></svg>
        </div>
        <details class="data-table"><summary>Accessible fleet pressure data</summary>
          <div class="table-actions">
            <span id="pressure-table-count" class="result-count" role="status" aria-live="polite"></span>
            <button id="pressure-table-more" type="button" aria-controls="pressure-table-body" hidden>Show more samples</button>
          </div>
          <div class="table-scroll"><table id="pressure-table"><caption>Timestamped whole-host fleet and build-pressure samples</caption><thead><tr><th>Sample time</th><th>Fleet source</th><th>Fleet observed</th><th>Build source</th><th>Build observed</th><th>Binding</th><th>Load</th><th>Occupied</th><th>Configured / max / effective</th><th>Build capacity</th><th>Active / queued</th><th>Oldest wait</th></tr></thead><tbody id="pressure-table-body"></tbody></table></div>
        </details>
      </section>

      <section id="ticket-lifecycle" class="panel" aria-labelledby="ticket-lifecycle-title">
        <div class="section-heading">
          <div><p class="kicker">05 / ticket phases</p><h2 id="ticket-lifecycle-title">Ticket lifecycle</h2></div>
          <p>Real dispatch, setup, implementation, test, PR, review, and rework boundaries.</p>
        </div>
        <div class="controls lifecycle-controls">
          <label>Ticket<select id="ticket-filter"><option value="">All tickets</option></select></label>
          <label>Zoom<input id="lifecycle-zoom" type="range" min="1" max="6" step="0.5" value="1"></label>
          <button id="reset-zoom" type="button">Reset view</button>
          <span id="lifecycle-count" class="result-count" role="status" aria-live="polite"></span>
        </div>
        <div id="phase-legend" class="phase-legend" aria-label="Visible lifecycle phases"></div>
        <p id="lifecycle-state" class="empty-state" hidden></p>
        <div class="chart-viewport lifecycle-viewport" tabindex="0" aria-label="Scrollable per-ticket lifecycle chart">
          <svg id="lifecycle-chart" class="chart lifecycle-chart" role="img" aria-labelledby="lifecycle-chart-title lifecycle-chart-description">
            <title id="lifecycle-chart-title">Per-ticket lifecycle chart</title>
            <desc id="lifecycle-chart-description">Each row is a ticket. Focus a phase marker for exact boundaries and outcomes.</desc>
          </svg>
        </div>
        <output id="lifecycle-detail" class="focus-detail" aria-live="polite">Focus or hover a phase for exact boundaries.</output>
        <details class="data-table"><summary>Accessible lifecycle interval table</summary>
          <div class="table-scroll"><table id="lifecycle-table"><caption>Lifecycle intervals for visible tickets</caption><thead><tr><th>Ticket</th><th>Phase</th><th>Start</th><th>End</th><th>Status</th><th>Outcome</th></tr></thead><tbody id="lifecycle-table-body"></tbody></table></div>
        </details>
      </section>

      <section id="resource-profiles" class="panel" aria-labelledby="resource-profiles-title">
        <div class="section-heading">
          <div><p class="kicker">06 / distribution</p><h2 id="resource-profiles-title">Resource profiles</h2></div>
          <p>Measured samples only; unavailable observations remain separately counted.</p>
        </div>
        <div class="table-scroll"><table id="profile-table"><caption>Per-actor resource distribution</caption><thead><tr><th>Actor</th><th>Metric</th><th>Samples</th><th>Minimum</th><th>Median</th><th>P95</th><th>Maximum</th></tr></thead><tbody id="profile-table-body"></tbody></table></div>
      </section>

      <section id="operational-notes" class="panel notes-panel" aria-labelledby="operational-notes-title">
        <div class="section-heading">
          <div><p class="kicker">07 / interpretation</p><h2 id="operational-notes-title">Operational notes</h2></div>
          <p>Evidence-led observations, not hidden heuristics.</p>
        </div>
        <ul id="notes-list" class="notes-list"></ul>
      </section>
    </main>
    <footer><p>Generated by <code>aiur telemetry dashboard</code>. No external assets or runtime requests.</p></footer>
    <noscript><p class="noscript">JavaScript is required to draw the inline dataset. The file remains offline and makes no network requests.</p></noscript>
    """
  end
end
