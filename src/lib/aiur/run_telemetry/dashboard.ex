defmodule Aiur.RunTelemetry.Dashboard do
  @moduledoc """
  Generates the canonical, backend-agnostic telemetry dashboard artifact.

  The result is one portable HTML file: its styles, scripts, normalized report
  data, charts, accessible tables, and operational notes are all inline. It
  performs no browser-side network requests.
  """

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
      styles(),
      "</style></head><body>",
      body(),
      "<script id=\"aiur-data\" type=\"application/json\">",
      json,
      "</script><script>",
      javascript(),
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

      <section id="ticket-lifecycle" class="panel" aria-labelledby="ticket-lifecycle-title">
        <div class="section-heading">
          <div><p class="kicker">04 / ticket phases</p><h2 id="ticket-lifecycle-title">Ticket lifecycle</h2></div>
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
          <div><p class="kicker">05 / distribution</p><h2 id="resource-profiles-title">Resource profiles</h2></div>
          <p>Measured samples only; unavailable observations remain separately counted.</p>
        </div>
        <div class="table-scroll"><table id="profile-table"><caption>Per-actor resource distribution</caption><thead><tr><th>Actor</th><th>Metric</th><th>Samples</th><th>Minimum</th><th>Median</th><th>P95</th><th>Maximum</th></tr></thead><tbody id="profile-table-body"></tbody></table></div>
      </section>

      <section id="operational-notes" class="panel notes-panel" aria-labelledby="operational-notes-title">
        <div class="section-heading">
          <div><p class="kicker">06 / interpretation</p><h2 id="operational-notes-title">Operational notes</h2></div>
          <p>Evidence-led observations, not hidden heuristics.</p>
        </div>
        <ul id="notes-list" class="notes-list"></ul>
      </section>
    </main>
    <footer><p>Generated by <code>aiur telemetry dashboard</code>. No external assets or runtime requests.</p></footer>
    <noscript><p class="noscript">JavaScript is required to draw the inline dataset. The file remains offline and makes no network requests.</p></noscript>
    """
  end

  defp styles do
    ~S"""
    :root {
      --canvas: #f7f7f8; --paper: #ffffff; --ink: #202123; --muted: #6e6e80;
      --line: #dedee5; --line-strong: #b9bbc6; --accent: #10a37f; --accent-dark: #087a60;
      --accent-soft: #e7f7f2; --danger: #b42318; --danger-soft: #fff0ee; --amber: #9a6700;
      --amber-soft: #fff7d6; --blue: #2563a6; --violet: #7157a8; --shadow: 0 14px 45px rgba(32,33,35,.08);
      font-family: "Söhne", "SF Pro Text", -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      color: var(--ink); background: var(--canvas); font-synthesis: none;
    }
    * { box-sizing: border-box; }
    html { scroll-behavior: smooth; }
    body { margin: 0; background: radial-gradient(circle at 8% 0%, #ecfaf5 0, transparent 27rem), var(--canvas); color: var(--ink); }
    button, select, input { font: inherit; }
    button, select { border: 1px solid var(--line-strong); border-radius: .55rem; background: var(--paper); color: var(--ink); min-height: 2.45rem; padding: .45rem .7rem; }
    button { cursor: pointer; font-weight: 650; }
    button:hover { border-color: var(--accent); color: var(--accent-dark); }
    :focus-visible { outline: 3px solid rgba(16,163,127,.35); outline-offset: 3px; }
    .skip-link { position: fixed; left: 1rem; top: -5rem; z-index: 10; background: var(--ink); color: white; padding: .7rem 1rem; border-radius: .5rem; }
    .skip-link:focus { top: 1rem; }
    .hero { max-width: 1440px; margin: 0 auto; padding: clamp(3.5rem, 7vw, 7rem) clamp(1rem, 4vw, 4rem) 2.25rem; display: grid; grid-template-columns: minmax(0, 1.35fr) minmax(18rem, .65fr); gap: 3rem; align-items: end; }
    .eyebrow, .kicker { text-transform: uppercase; letter-spacing: .13em; font-size: .72rem; font-weight: 800; color: var(--accent-dark); margin: 0 0 .85rem; }
    .signal { display: inline-block; width: .55rem; height: .55rem; margin-right: .55rem; border-radius: 50%; background: var(--accent); box-shadow: 0 0 0 .35rem rgba(16,163,127,.12); }
    h1 { max-width: 13ch; margin: 0; font-size: clamp(2.65rem, 6vw, 5.6rem); line-height: .96; letter-spacing: -.055em; }
    .lede { max-width: 48rem; color: var(--muted); font-size: clamp(1rem, 1.5vw, 1.25rem); line-height: 1.6; margin: 1.5rem 0 .65rem; }
    .generated { color: var(--muted); font-size: .82rem; }
    .hero-stats { margin: 0; display: grid; grid-template-columns: repeat(2, 1fr); gap: .7rem; }
    .stat { background: rgba(255,255,255,.85); border: 1px solid var(--line); border-radius: .85rem; padding: 1rem; box-shadow: var(--shadow); }
    .stat dt { color: var(--muted); font-size: .72rem; text-transform: uppercase; letter-spacing: .08em; }
    .stat dd { margin: .3rem 0 0; font: 750 1.7rem/1.1 "Söhne Mono", ui-monospace, monospace; }
    main { max-width: 1440px; margin: 0 auto; padding: 0 clamp(1rem, 4vw, 4rem) 4rem; }
    .panel { background: rgba(255,255,255,.94); border: 1px solid var(--line); border-radius: 1rem; padding: clamp(1.1rem, 2.5vw, 2rem); margin: 1rem 0; box-shadow: 0 3px 16px rgba(32,33,35,.035); animation: rise .45s both; }
    .panel:nth-child(2) { animation-delay: .04s; } .panel:nth-child(3) { animation-delay: .08s; } .panel:nth-child(4) { animation-delay: .12s; }
    .section-heading { display: flex; justify-content: space-between; gap: 2rem; align-items: end; margin-bottom: 1.5rem; }
    .section-heading h2 { margin: 0; font-size: clamp(1.45rem, 2.5vw, 2.2rem); letter-spacing: -.035em; }
    .section-heading > p { max-width: 35rem; margin: 0; color: var(--muted); line-height: 1.5; text-align: right; }
    .evidence-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: .8rem; }
    .subpanel { border: 1px solid var(--line); border-radius: .75rem; padding: 1rem; min-width: 0; }
    .subpanel h3 { margin: 0 0 .8rem; font-size: .85rem; text-transform: uppercase; letter-spacing: .08em; }
    .facts { margin: 0; display: grid; gap: .75rem; }
    .fact dt { color: var(--muted); font-size: .75rem; } .fact dd { margin: .15rem 0 0; overflow-wrap: anywhere; }
    .event-list, .warning-list, .notes-list { margin: 0; padding-left: 1.2rem; }
    .event-list li, .warning-list li, .notes-list li { margin: .5rem 0; line-height: 1.45; }
    .warning-panel { background: linear-gradient(145deg, #fff, var(--amber-soft)); }
    .warning-list { color: #664500; }
    .finding-summary { color: var(--muted); margin: -.5rem 0 1rem; }
    .finding-list { display: grid; grid-template-columns: repeat(auto-fit, minmax(16rem, 1fr)); gap: .7rem; }
    .finding { border: 1px solid var(--line); border-left: 4px solid var(--line-strong); border-radius: .65rem; padding: .9rem; }
    .finding[data-status="broken"] { border-left-color: var(--danger); background: var(--danger-soft); }
    .finding[data-status="resolved"] { border-left-color: var(--accent); background: var(--accent-soft); }
    .finding[data-status="pending"] { border-left-color: var(--amber); background: var(--amber-soft); }
    .finding h3 { margin: 0; font-size: 1rem; } .finding p { margin: .45rem 0 0; color: var(--muted); font-size: .88rem; }
    .controls { display: flex; flex-wrap: wrap; align-items: end; gap: .8rem 1.2rem; margin-bottom: 1rem; padding: .85rem; border: 1px solid var(--line); border-radius: .75rem; background: #fafafa; }
    .controls label { display: grid; gap: .3rem; color: var(--muted); font-size: .76rem; font-weight: 700; }
    .controls fieldset { border: 0; padding: 0; margin: 0; min-width: min(100%, 28rem); }
    .controls legend { color: var(--muted); font-size: .76rem; font-weight: 700; margin-bottom: .35rem; }
    .check-row { display: flex; flex-wrap: wrap; gap: .5rem .8rem; }
    .actor-check { display: inline-flex; align-items: center; gap: .35rem; color: var(--ink); font: 500 .84rem/1.2 "Söhne Mono", ui-monospace, monospace; }
    .actor-check i { width: .65rem; height: .65rem; border-radius: 50%; display: inline-block; }
    .chart-viewport { overflow-x: auto; border: 1px solid var(--line); border-radius: .75rem; background: #fdfdfd; min-height: 20rem; }
    .chart { display: block; width: 100%; min-width: 55rem; height: 21rem; color: var(--muted); }
    .lifecycle-viewport { min-height: 12rem; } .lifecycle-chart { min-width: 62rem; height: auto; }
    .grid-line { stroke: #e8e8ed; stroke-width: 1; } .axis-label { fill: var(--muted); font-size: 11px; }
    .restart-line { stroke: var(--danger); stroke-width: 1.4; stroke-dasharray: 5 4; opacity: .7; }
    .gap-band { fill: var(--amber-soft); } .sample-point { stroke: white; stroke-width: 2; cursor: crosshair; }
    .unavailable-mark { stroke: var(--line-strong); stroke-width: 2; }
    .phase-mark { stroke: white; stroke-width: 1.5; cursor: crosshair; }
    .row-band { fill: #fafafa; } .row-label { fill: var(--ink); font: 700 12px "Söhne Mono", ui-monospace, monospace; }
    .focus-detail { display: block; min-height: 2.7rem; margin-top: .65rem; padding: .7rem .85rem; border-radius: .6rem; background: var(--ink); color: white; font: 500 .8rem/1.5 "Söhne Mono", ui-monospace, monospace; }
    .empty-state { margin: 1rem 0; padding: 1rem; border: 1px dashed var(--line-strong); border-radius: .65rem; color: var(--muted); }
    .result-count { margin-left: auto; color: var(--muted); font-size: .82rem; }
    .phase-legend { display: flex; flex-wrap: wrap; gap: .4rem .8rem; min-height: 1.5rem; margin: -.2rem 0 .65rem; color: var(--muted); font-size: .72rem; }
    .phase-key { display: inline-flex; align-items: center; gap: .3rem; }
    .phase-key i { display: inline-block; width: .65rem; height: .65rem; border-radius: .2rem; }
    .data-table { margin-top: .7rem; } .data-table summary { cursor: pointer; color: var(--accent-dark); font-weight: 700; }
    .table-actions { display: flex; justify-content: flex-end; align-items: center; gap: .8rem; margin-top: .7rem; }
    .table-actions .result-count { margin-left: 0; }
    .table-actions button[hidden] { display: none; }
    .table-scroll { overflow-x: auto; margin-top: .7rem; }
    table { width: 100%; border-collapse: collapse; font-size: .82rem; }
    caption { text-align: left; color: var(--muted); margin-bottom: .55rem; }
    th, td { padding: .65rem .7rem; border-bottom: 1px solid var(--line); text-align: left; white-space: nowrap; }
    th { color: var(--muted); text-transform: uppercase; letter-spacing: .06em; font-size: .68rem; }
    tbody tr:hover { background: var(--accent-soft); }
    code { font-family: "Söhne Mono", ui-monospace, monospace; font-size: .9em; }
    .notes-panel { background: linear-gradient(135deg, #fff 30%, var(--accent-soft)); }
    .notes-list { display: grid; grid-template-columns: repeat(2, minmax(0,1fr)); gap: .3rem 2rem; }
    footer { max-width: 1440px; margin: 0 auto; padding: 0 4rem 3rem; color: var(--muted); font-size: .8rem; }
    .noscript { margin: 1rem; padding: 1rem; background: var(--danger-soft); }
    @keyframes rise { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: none; } }
    @media (max-width: 850px) {
      .hero { grid-template-columns: 1fr; gap: 1.5rem; } .evidence-grid { grid-template-columns: 1fr; }
      .section-heading { display: block; } .section-heading > p { text-align: left; margin-top: .6rem; }
      .notes-list { grid-template-columns: 1fr; } footer { padding-inline: 1rem; }
    }
    @media (prefers-reduced-motion: reduce) {
      html { scroll-behavior: auto; } *, *::before, *::after { animation-duration: .01ms !important; animation-iteration-count: 1 !important; transition-duration: .01ms !important; }
    }
    """
  end

  defp javascript do
    ~S"""
    (() => {
      "use strict";
      const data = JSON.parse(document.getElementById("aiur-data").textContent);
      const NS = "http://www.w3.org/2000/svg";
      const palette = ["#10a37f", "#2563a6", "#7157a8", "#d97706", "#be3d78", "#4f6b45", "#8b5e34"];
      const phaseColors = {dispatch:"#5f6b7a", prewarm:"#2b78a0", workspace_setup:"#7157a8", workspace_ownership:"#5b4b8a", agent_spinup:"#9764c7", implement:"#10a37f", build_test:"#d97706", pr_opened:"#2563a6", review_pause:"#9a6700", comment_received:"#be3d78", rework_start:"#b42318", agent_pause:"#7a5d00", agent_resume:"#087a60", pr_merged:"#202123"};
      const metrics = [
        ["cpu_percent", "CPU", "%"], ["rss_bytes", "RSS", "bytes"], ["fd_count", "File descriptors", "count"],
        ["read_bytes_per_second", "Read I/O", "bytes/s"], ["write_bytes_per_second", "Write I/O", "bytes/s"],
        ["system_fd_used", "System FD used", "count"], ["system_fd_headroom_ratio", "System FD headroom", "ratio"]
      ];
      const actorTablePageSize = 500;
      let actorTableRows = [], actorTableOffset = 0, actorTableMetric = "cpu_percent";
      const $ = id => document.getElementById(id);
      const dateFormatter = new Intl.DateTimeFormat(undefined, {dateStyle:"medium", timeStyle:"medium"});
      const node = (tag, className, text) => { const item = document.createElement(tag); if (className) item.className = className; if (text !== undefined) item.textContent = text; return item; };
      const svgNode = (tag, attrs = {}) => { const item = document.createElementNS(NS, tag); Object.entries(attrs).forEach(([key, value]) => item.setAttribute(key, String(value))); return item; };
      const clear = element => element.replaceChildren();
      const resetChart = (svg, titleId, titleText, descriptionId, descriptionText) => {
        clear(svg);
        const title=svgNode("title",{id:titleId}); title.textContent=titleText;
        const description=svgNode("desc",{id:descriptionId}); description.textContent=descriptionText;
        svg.append(title,description);
      };
      const sortedEntries = object => Object.entries(object || {}).sort(([a], [b]) => a.localeCompare(b, undefined, {numeric:true}));
      const date = value => { if (!value) return "Unavailable"; const parsed=new Date(value); return Number.isNaN(parsed.getTime()) ? "Unavailable" : dateFormatter.format(parsed); };
      const numeric = value => { if (value === null || value === undefined || value === "") return null; const parsed=Number(value); return Number.isFinite(parsed) ? parsed : null; };
      const number = value => { const parsed=numeric(value); return parsed === null ? "—" : new Intl.NumberFormat(undefined, {maximumFractionDigits:2}).format(parsed); };
      const bytes = value => { const n=numeric(value); if (n === null) return "—"; const units = ["B","KiB","MiB","GiB","TiB"]; let i=0, v=n; while (Math.abs(v)>=1024 && i<units.length-1) {v/=1024;i++;} return `${new Intl.NumberFormat(undefined,{maximumFractionDigits:1}).format(v)} ${units[i]}`; };
      const metricMeta = key => metrics.find(metric => metric[0] === key) || [key, key.replaceAll("_", " "), "count"];
      const metricValue = (key, value) => { const unit=metricMeta(key)[2]; if (unit === "bytes" || unit === "bytes/s") return `${bytes(value)}${unit === "bytes/s" && value != null ? "/s" : ""}`; if (unit === "%") return value == null ? "—" : `${number(value)}%`; if (unit === "ratio") return value == null ? "—" : `${number(Number(value)*100)}%`; return number(value); };
      const duration = ms => ms == null ? "open" : ms < 1000 ? `${ms} ms` : ms < 60000 ? `${number(ms/1000)} s` : `${number(ms/60000)} min`;
      const appendFact = (target, term, description) => { const wrap=node("div","fact"); wrap.append(node("dt",null,term), node("dd",null,description)); target.append(wrap); };
      const tableEmpty = (body, columns, message) => { const row=node("tr"); const cell=node("td",null,message); cell.colSpan=columns; row.append(cell); body.append(row); };
      const bindDetail = (item, text, output) => { item.addEventListener("mouseenter", () => output.textContent=text); item.addEventListener("focus", () => output.textContent=text); };
      const actorLabel = actor => actor === "_operator" ? "Executor" : actor;
      const unavailableReason = reason => ({
        operator_process_unavailable: "Executor process unavailable",
        operator_pid_unavailable: "Executor PID unavailable"
      })[reason] || String(reason || "unknown reason");

      function renderHeader() {
        $("generated-at").textContent = date(data.generated_at);
        $("generated-at").dateTime = data.generated_at;
        const stats = [["Records", data.provenance.record_count || 0], ["Actors", Object.keys(data.actors).length], ["Tickets", Object.keys(data.tickets).length], ["Findings", data.findings.length]];
        stats.forEach(([label,value]) => { const wrap=node("div","stat"); wrap.append(node("dt",null,label),node("dd",null,String(value))); $("hero-stats").append(wrap); });
      }

      function renderEvidence() {
        const provenance=$("provenance-list");
        appendFact(provenance,"Time range",data.provenance.time_range ? `${date(data.provenance.time_range.start)} → ${date(data.provenance.time_range.end)}` : "No valid timestamps");
        appendFact(provenance,"Telemetry files",String((data.provenance.files || []).length));
        appendFact(provenance,"Schema",(data.provenance.schema_versions || []).join(", ") || "Unavailable");
        (data.provenance.inputs || []).forEach((input,index) => appendFact(provenance,`Input ${index+1}`,input));
        const restarts=$("restart-list");
        if (!data.restarts.length) restarts.append(node("li",null,"No daemon restart markers were recorded."));
        data.restarts.forEach(restart => restarts.append(node("li",null,`${date(restart.timestamp)} · ${restart.boot_id}${restart.existing_records ? " · resumed durable log" : " · new log"}`)));
        const warnings=$("warning-list");
        if (!data.warnings.length) warnings.append(node("li",null,"No reducer or runtime warnings."));
        data.warnings.forEach(warning => { const detail=[warning.type, warning.reason, warning.endpoint, warning.path && warning.path.split("/").pop()].filter(Boolean).join(" · "); warnings.append(node("li",null,detail)); });
      }

      function renderFindings() {
        const list=$("finding-list"), summary=$("finding-summary");
        if (!data.findings.length) { summary.textContent="No review pause/resume findings."; list.append(node("p","empty-state","No review pause/resume findings.")); return; }
        const counts=data.findings.reduce((acc,item) => (acc[item.status]=(acc[item.status]||0)+1,acc),{});
        summary.textContent=["broken","pending","resolved","closed"].filter(key=>counts[key]).map(key=>`${counts[key]} ${key}`).join(" · ");
        const labels={broken:["!","Broken pause → resume"],pending:["…","Awaiting listener response"],resolved:["✓","Pause → resume observed"],closed:["◇","Window closed by merge"]};
        data.findings.forEach(finding => { const card=node("article","finding"); card.dataset.status=finding.status; const [mark,label]=labels[finding.status]||["•",finding.status]; card.append(node("h3",null,`${mark} Ticket ${finding.ticket} · ${label}`),node("p",null,`Comment ${date(finding.comment_at)}${finding.missing.length ? ` · missing ${finding.missing.join(" + ")}` : " · complete"}`)); list.append(card); });
      }

      function setupActorControls() {
        const select=$("resource-metric"); metrics.forEach(([key,label]) => { const option=node("option",null,label); option.value=key; select.append(option); });
        const filters=$("actor-filters"); sortedEntries(data.actors).forEach(([actor],index) => { const label=node("label","actor-check"); const input=node("input"); input.type="checkbox"; input.checked=true; input.value=actor; input.dataset.color=palette[index%palette.length]; const dot=node("i"); dot.style.background=input.dataset.color; label.append(input,dot,document.createTextNode(actorLabel(actor))); filters.append(label); input.addEventListener("change",renderActorChart); });
        select.addEventListener("change",renderActorChart);
        $("actor-table-more").addEventListener("click",appendActorTablePage);
        renderActorChart();
      }

      function actorSelection() { return [...$("actor-filters").querySelectorAll("input:checked")].map(input=>input.value); }
      function actorColor(actor) { const input=[...$("actor-filters").querySelectorAll("input")].find(item=>item.value===actor); return input ? input.dataset.color : palette[0]; }
      function scale(value,min,max,start,end) { return max===min ? (start+end)/2 : start+(value-min)*(end-start)/(max-min); }
      function grid(svg,left,right,top,bottom,yMax,metric) {
        for (let i=0;i<=4;i++) { const y=top+(bottom-top)*i/4; svg.append(svgNode("line",{x1:left,x2:right,y1:y,y2:y,class:"grid-line"})); const label=svgNode("text",{x:left-8,y:y+4,"text-anchor":"end",class:"axis-label"}); label.textContent=metricValue(metric,yMax*(1-i/4)); svg.append(label); }
      }

      function decimateSamples(samples, metric, limit) {
        if (samples.length <= limit) return samples;
        const bucketCount=Math.max(1,Math.floor((limit-2)/3)), interior=Math.max(samples.length-2,1), selected=[{index:0,sample:samples[0]}];
        for (let bucket=0;bucket<bucketCount;bucket++) {
          const start=1+Math.floor(bucket*interior/bucketCount), end=Math.min(samples.length-1,1+Math.floor((bucket+1)*interior/bucketCount));
          let minimum=null, maximum=null, unavailable=null;
          for (let index=start;index<end;index++) {
            const sample=samples[index], value=numeric(sample[metric]), candidate={index,sample,value};
            if (sample.availability !== "measured" || value === null) unavailable ||= candidate;
            else { if (!minimum || value<minimum.value) minimum=candidate; if (!maximum || value>maximum.value) maximum=candidate; }
          }
          [minimum,maximum,unavailable].filter(Boolean).sort((a,b)=>a.index-b.index).forEach(candidate => {
            if (selected[selected.length-1].index !== candidate.index) selected.push(candidate);
          });
        }
        selected.push({index:samples.length-1,sample:samples[samples.length-1]});
        return selected.filter((item,index,list)=>index===0 || item.index!==list[index-1].index).map(item=>item.sample);
      }

      function resetActorTable(rows, metric, emptyMessage) {
        actorTableRows=rows; actorTableMetric=metric; actorTableOffset=0; clear($("actor-table-body"));
        if (emptyMessage) {
          tableEmpty($("actor-table-body"),5,emptyMessage); $("actor-table-count").textContent=""; $("actor-table-more").hidden=true;
        } else appendActorTablePage();
      }

      function appendActorTablePage() {
        const body=$("actor-table-body"), next=Math.min(actorTableOffset+actorTablePageSize,actorTableRows.length);
        actorTableRows.slice(actorTableOffset,next).forEach(sample => { const row=node("tr"); [date(sample.timestamp),actorLabel(sample.actor),sample.availability,metricValue(actorTableMetric,sample[actorTableMetric]),sample.boot_id].forEach(value=>row.append(node("td",null,value))); body.append(row); });
        actorTableOffset=next; $("actor-table-count").textContent=`Showing ${actorTableOffset} of ${actorTableRows.length} samples`; $("actor-table-more").hidden=actorTableOffset>=actorTableRows.length;
      }

      function renderActorChart() {
        const svg=$("actor-chart"), state=$("actor-state"), detail=$("actor-detail"); resetChart(svg,"actor-chart-title","Per-actor resource timeline","actor-chart-description","Focus a point to read its exact actor, time, and value.");
        const actorNames=actorSelection(), metric=$("resource-metric").value || "cpu_percent";
        const actors=actorNames.map(name=>data.actors[name]).filter(Boolean);
        const allSamples=actors.flatMap(actor=>actor.samples || []);
        if (!Object.keys(data.actors).length) { state.hidden=false; state.textContent="No actor resource samples were recorded."; resetActorTable([],metric,"No actor resource samples were recorded."); svg.setAttribute("height","320"); return; }
        if (!actors.length) { state.hidden=false; state.textContent="Select at least one actor."; resetActorTable([],metric,"No actors selected."); return; }
        if (!allSamples.length) { state.hidden=false; state.textContent="No samples exist for the selected actors."; resetActorTable([],metric,"No samples exist for the selected actors."); return; }
        state.hidden=true;
        const width=1000,height=320,left=92,right=975,top=25,bottom=280;
        svg.setAttribute("viewBox",`0 0 ${width} ${height}`); svg.setAttribute("height",String(height));
        const [minTime,maxTime]=allSamples.reduce(([minimum,maximum],sample)=>{ const value=Number(sample.timestamp_ms); return Number.isFinite(value)?[Math.min(minimum,value),Math.max(maximum,value)]:[minimum,maximum]; },[Infinity,-Infinity]);
        const yMax=allSamples.reduce((maximum,sample)=>{ const value=numeric(sample[metric]); return value === null ? maximum : Math.max(maximum,value); },1);
        grid(svg,left,right,top,bottom,yMax,metric);
        data.restarts.forEach(restart => { const time=Date.parse(restart.timestamp); if (time>=minTime && time<=maxTime) { const x=scale(time,minTime,maxTime,left,right); const line=svgNode("line",{x1:x,x2:x,y1:top,y2:bottom,class:"restart-line"}); const title=svgNode("title"); title.textContent=`Daemon restart ${restart.boot_id} at ${date(restart.timestamp)}`; line.append(title); svg.append(line); } });
        actors.forEach(actor => {
          (actor.gaps || []).forEach(gap => { const x=scale(Date.parse(gap.start_at),minTime,maxTime,left,right), x2=scale(Date.parse(gap.end_at),minTime,maxTime,left,right); svg.append(svgNode("rect",{x,y:top,width:Math.max(x2-x,2),height:bottom-top,class:"gap-band"})); });
          let segment=[]; const flush=()=>{ if (segment.length>1) { const path=svgNode("path",{d:segment.map((point,index)=>`${index?"L":"M"}${point.x},${point.y}`).join(" "),fill:"none",stroke:actorColor(actor.actor),"stroke-width":2.5}); svg.append(path); } segment=[]; };
          const chartLimit=Math.max(60,Math.floor(1800/actors.length));
          decimateSamples(actor.samples || [],metric,chartLimit).forEach(sample => {
            const x=scale(Number(sample.timestamp_ms),minTime,maxTime,left,right), value=numeric(sample[metric]);
            if (sample.availability === "measured" && value !== null) {
              const y=scale(value,0,yMax,bottom,top); segment.push({x,y}); const circle=svgNode("circle",{cx:x,cy:y,r:5,fill:actorColor(actor.actor),class:"sample-point",tabindex:0,role:"img"});
              const label=`${actorLabel(actor.actor)} · ${metricMeta(metric)[1]} ${metricValue(metric,value)} · ${date(sample.timestamp)}`; circle.setAttribute("aria-label",label); const title=svgNode("title"); title.textContent=label; circle.append(title); bindDetail(circle,label,detail); svg.append(circle);
            } else { flush(); const group=svgNode("g",{tabindex:0,role:"img","aria-label":`${actorLabel(actor.actor)} unavailable at ${date(sample.timestamp)}: ${unavailableReason(sample.unavailable_reason)}`}); group.append(svgNode("line",{x1:x-4,x2:x+4,y1:bottom-4,y2:bottom+4,class:"unavailable-mark"}),svgNode("line",{x1:x-4,x2:x+4,y1:bottom+4,y2:bottom-4,class:"unavailable-mark"})); bindDetail(group,group.getAttribute("aria-label"),detail); svg.append(group); }
          }); flush();
        });
        resetActorTable(allSamples,metric);
        const startLabel=svgNode("text",{x:left,y:307,class:"axis-label"}); startLabel.textContent=date(new Date(minTime).toISOString()); const endLabel=svgNode("text",{x:right,y:307,"text-anchor":"end",class:"axis-label"}); endLabel.textContent=date(new Date(maxTime).toISOString()); svg.append(startLabel,endLabel);
      }

      function setupLifecycleControls() {
        const filter=$("ticket-filter"); sortedEntries(data.tickets).forEach(([ticket])=>{ const option=node("option",null,`Ticket ${ticket}`); option.value=ticket; filter.append(option); });
        filter.addEventListener("change",renderLifecycle); $("lifecycle-zoom").addEventListener("input",renderLifecycle);
        $("reset-zoom").addEventListener("click",()=>{ filter.value=""; $("lifecycle-zoom").value="1"; renderLifecycle(); }); renderLifecycle();
      }

      function visibleTickets() { const selected=$("ticket-filter").value; return sortedEntries(data.tickets).filter(([ticket])=>!selected || ticket===selected); }
      function renderLifecycle() {
        const svg=$("lifecycle-chart"),state=$("lifecycle-state"),table=$("lifecycle-table-body"),detail=$("lifecycle-detail"),legend=$("phase-legend"); resetChart(svg,"lifecycle-chart-title","Per-ticket lifecycle chart","lifecycle-chart-description","Each row is a ticket. Focus a phase marker for exact boundaries and outcomes."); clear(table); clear(legend);
        const tickets=visibleTickets(), zoom=Number($("lifecycle-zoom").value), intervals=tickets.flatMap(([ticket,item])=>(item.intervals||[]).map(interval=>({...interval,ticket})));
        $("lifecycle-count").textContent=`${tickets.length} ticket${tickets.length===1?"":"s"} · ${intervals.length} phase${intervals.length===1?"":"s"}`;
        [...new Set(intervals.map(interval=>interval.phase))].sort().forEach(phase=>{ const key=node("span","phase-key"); const swatch=node("i"); swatch.style.background=phaseColors[phase]||"#6e6e80"; key.append(swatch,document.createTextNode(phase.replaceAll("_"," "))); legend.append(key); });
        if (!Object.keys(data.tickets).length) { state.hidden=false; state.textContent="No ticket lifecycle events were recorded."; tableEmpty(table,6,"No ticket lifecycle events were recorded."); svg.setAttribute("height","170"); return; }
        state.hidden=true; const width=1050,height=Math.max(150,tickets.length*58+70),left=125,right=1020,top=28;
        svg.setAttribute("viewBox",`0 0 ${width} ${height}`); svg.setAttribute("width",String(Math.round(width*zoom))); svg.setAttribute("height",String(height));
        const starts=intervals.map(item=>Number(item.start_ms)).filter(Number.isFinite), ends=intervals.map(item=>Number(item.end_ms || item.start_ms)).filter(Number.isFinite); const minTime=Math.min(...starts),maxTime=Math.max(...ends,minTime+1);
        tickets.forEach(([ticket,item],rowIndex)=>{ const y=top+rowIndex*58; if (rowIndex%2===0) svg.append(svgNode("rect",{x:0,y:y-17,width,height:48,class:"row-band"})); const label=svgNode("text",{x:12,y:y+5,class:"row-label"}); label.textContent=`#${ticket}`; svg.append(label);
          (item.intervals||[]).forEach(interval=>{ const x=scale(Number(interval.start_ms),minTime,maxTime,left,right), end=Number(interval.end_ms || interval.start_ms), x2=scale(end,minTime,maxTime,left,right), color=phaseColors[interval.phase]||"#6e6e80"; let mark;
            if (interval.duration_ms == null || interval.status === "point" || interval.status === "orphan_end") mark=svgNode("circle",{cx:x,cy:y,r:7,fill:color,class:"phase-mark",tabindex:0,role:"img"});
            else mark=svgNode("rect",{x,y:y-8,width:Math.max(x2-x,6),height:16,rx:5,fill:color,class:"phase-mark",tabindex:0,role:"img"});
            const labelText=`Ticket ${ticket} · ${interval.phase.replaceAll("_"," ")} · ${date(interval.start_at)}${interval.end_at?` → ${date(interval.end_at)} (${duration(interval.duration_ms)})`:" · open/point"}${interval.outcome?` · ${interval.outcome}`:""}`; mark.setAttribute("aria-label",labelText); const title=svgNode("title"); title.textContent=labelText; mark.append(title); bindDetail(mark,labelText,detail); svg.append(mark);
            const row=node("tr"); [ticket,interval.phase.replaceAll("_"," "),date(interval.start_at),interval.end_at?date(interval.end_at):"—",interval.status,interval.outcome||"—"].forEach(value=>row.append(node("td",null,value))); table.append(row);
          });
        });
        const startLabel=svgNode("text",{x:left,y:height-18,class:"axis-label"}); startLabel.textContent=date(new Date(minTime).toISOString()); const endLabel=svgNode("text",{x:right,y:height-18,"text-anchor":"end",class:"axis-label"}); endLabel.textContent=date(new Date(maxTime).toISOString()); svg.append(startLabel,endLabel);
      }

      function renderProfiles() {
        const body=$("profile-table-body"); let count=0;
        sortedEntries(data.actors).forEach(([actor,item])=>{ sortedEntries(item.profile||{}).forEach(([metric,stats])=>{ const row=node("tr"); [actorLabel(actor),metricMeta(metric)[1],String(stats.count),metricValue(metric,stats.min),metricValue(metric,stats.median),metricValue(metric,stats.p95),metricValue(metric,stats.max)].forEach(value=>row.append(node("td",null,value))); body.append(row); count++; }); });
        if (!count) tableEmpty(body,7,"No measured resource values are available for profiling.");
      }

      function renderNotes() {
        const samples=Object.values(data.actors).flatMap(actor=>actor.samples||[]), gaps=Object.values(data.actors).reduce((sum,actor)=>sum+(actor.gaps||[]).length,0), unavailable=samples.filter(sample=>sample.availability!=="measured").length, broken=data.findings.filter(f=>f.status==="broken").length;
        const notes=[
          broken ? `${broken} broken review wakeup path${broken===1?"":"s"} require Executor investigation.` : "No broken review pause → resume path is present in this dataset.",
          gaps ? `${gaps} within-boot sampling gap${gaps===1?"":"s"} exceeded the configured cadence.` : "No within-boot resource sampling gap exceeded the configured cadence.",
          `Unavailable samples: ${unavailable} of ${samples.length}. Missing values are excluded from resource distributions.`,
          `${data.restarts.length} daemon restart marker${data.restarts.length===1?"":"s"} preserve${data.restarts.length===1?"s":""} chronology across handoffs.`,
          `${data.warnings.length} reducer, runtime, or enrichment warning${data.warnings.length===1?"":"s"} retained without blocking the artifact.`
        ]; notes.forEach(text=>$("notes-list").append(node("li",null,text)));
      }

      renderHeader(); renderEvidence(); renderFindings(); setupActorControls(); setupLifecycleControls(); renderProfiles(); renderNotes();
    })();
    """
  end
end
