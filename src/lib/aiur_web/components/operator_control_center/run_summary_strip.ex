defmodule AiurWeb.OperatorControlCenter.RunSummaryStrip do
  @moduledoc "Compact, truthful current-run and provider-usage summary."

  use Phoenix.Component

  alias Aiur.CodingAgent
  alias Aiur.ModelAvailability

  # The dispatch-limits ledger's buckets, used to find the governing one when a
  # provider has no live meter observation this boot.
  @durable_windows ~w(hourly weekly monthly)

  # The provider card that leads the strip. The run summary moved out of the
  # strip into the compact above-filters section, so the first provider card
  # takes the position the Summary block used to occupy.
  @lead_provider :deepseek

  attr(:run, :map, required: true)
  attr(:usage, :map, required: true)
  attr(:meters, :map, required: true)
  attr(:github_quota, :map, default: %{state: :unknown, windows: %{}, attribution: [], coverage: nil, backoffs: []})
  attr(:now, :any, required: true)

  @spec run_summary_strip(map()) :: Phoenix.LiveView.Rendered.t()
  def run_summary_strip(assigns) do
    cards = provider_cards(assigns.usage, assigns.meters)

    assigns =
      assigns
      |> assign(:usage_ready?, Map.get(assigns.usage, :state) in [:ready, :partial, :stale])
      |> assign(:cards, cards)
      |> assign(:compressed?, compressed?(cards))

    ~H"""
    <section :if={@compressed?} class="run-summary is-compressed" aria-label="Provider and GitHub usage">
      <.compressed_meters cards={@cards} github_quota={@github_quota} now={@now} />
    </section>
    <section :if={not @compressed?} class="run-summary" aria-label="Provider and GitHub usage">
      <.github_quota_card quota={@github_quota} now={@now} />
      <.vendor_card :for={card <- @cards} card={card} usage_ready?={@usage_ready?} now={@now} />
    </section>
    """
  end

  # The strip is a quota glance, not a dashboard: past four panes the row stops
  # reading as one thing, so it collapses into a single grouped table. The
  # GitHub pane counts — it occupies a pane like any provider — so today's four
  # (GitHub plus three model providers) stay exactly as they are and the fifth
  # provider is what trips the compressed form.
  @max_panes 4

  defp compressed?(cards), do: length(cards) + 1 > @max_panes

  attr(:quota, :map, required: true)
  attr(:now, :any, required: true)

  defp github_quota_card(assigns) do
    assigns =
      assigns
      |> assign(:windows, github_windows(assigns.quota))
      |> assign(:attribution, github_attribution(assigns.quota))
      |> assign(:top_consumer, github_top_consumer(assigns.quota))
      |> assign(:coverage, github_coverage(assigns.quota))
      |> assign(:backoffs, github_backoffs(assigns.quota))

    ~H"""
    <div class="rs-block github-quota-card">
      <div class="rs-head">
        <span class="rs-logo rs-github-logo" aria-hidden="true">GH</span>
        <span class="rs-name">GitHub API</span>
        <div :if={@attribution} class="rs-head-stats">
          <div class="rs-stat">
            <span class="rs-stat-label">Window traffic</span>
            <span class="rs-stat-val">{@attribution.reads}R / {@attribution.writes}W</span>
          </div>
        </div>
      </div>
      <div class="rs-limits">
        <div :if={@windows == []} class="rs-limit">
          <div class="rs-limit-top">
            <span class="rs-limit-label">Quota</span>
            <span class="rs-limit-meta">Awaiting GitHub response</span>
          </div>
          <div class="rs-meter"><i style="width:0%"></i></div>
        </div>
        <div :for={window <- @windows} class="rs-limit">
          <div class="rs-limit-top">
            <span class="rs-limit-label">{github_window_label(window)}</span>
            <span class="rs-limit-meta">{github_window_meta(window, @now)}</span>
          </div>
          <div class="rs-meter">
            <i class={meter_class(window.used_percent, 90)} style={"width:#{window.used_percent}%"}></i>
          </div>
        </div>
        <div :for={backoff <- @backoffs} class="github-quota-backoff">
          <span class="rs-limit-label">{github_window_label(backoff)} backoff</span>
          <span class="rs-limit-meta">Secondary limit · {backoff.seconds_remaining}s left</span>
        </div>
        <div :if={@top_consumer} class="github-quota-attribution">
          <span class="rs-limit-label">Top consumer</span>
          <span class="rs-limit-meta">{github_top_consumer_meta(@top_consumer, @coverage)}</span>
        </div>
        <%!-- The ranking above only orders the calls Aiur can see, and it
              cannot see every call billed to the shared credential. Naming a
              leader without saying what share of the spend it was drawn from
              invited acting on 0.04% of the budget (#1805), so the coverage
              line renders whenever a window has been observed — including, and
              especially, when there is no leader to name. --%>
        <div :if={@coverage} class="github-quota-coverage">
          <span class="rs-limit-label">Attributed</span>
          <span class="rs-limit-meta">{github_coverage_meta(@coverage)}</span>
        </div>
      </div>
    </div>
    """
  end

  # The compact run summary, rendered above the Units table filters. The
  # Summary block that used to lead the strip lives here now: it only has room
  # to say something real when there are tickets still to work, so the section
  # hides entirely at zero remaining.
  attr(:run, :map, required: true)
  attr(:usage, :map, required: true)
  attr(:meters, :map, required: true)
  attr(:now, :any, required: true)

  @spec run_summary_compact(map()) :: Phoenix.LiveView.Rendered.t()
  def run_summary_compact(assigns) do
    run_state = Map.get(assigns.run, :state)
    remaining = remaining_count(run_state, assigns.run)

    assigns =
      assigns
      |> assign(:run_state, run_state)
      |> assign(:run_ready?, run_state in [:ready, :stale])
      |> assign(:remaining, remaining)
      |> assign(:spend_total, provider_spend_total(provider_cards(assigns.usage, assigns.meters)))

    ~H"""
    <section :if={@remaining && @remaining > 0} class="rs-block rs-summary-compact" aria-label="Run summary">
      <div class="rs-head">
        <img class="rs-logo" src="/aiur-logo.png" alt="" aria-hidden="true" />
        <span class="rs-name">Summary</span>
        <div class="rs-head-stats">
          <div class="rs-stat">
            <span class="rs-stat-label">Tickets</span>
            <span class="rs-stat-val">{@remaining} remain</span>
          </div>
          <div :if={@spend_total} class="rs-stat">
            <span class="rs-stat-label">Spend</span>
            <span class="rs-stat-val rs-stat-spend">{@spend_total}</span>
          </div>
        </div>
      </div>
      <div class="rs-progress">
        <div class="rs-limit-top">
          <span class="rs-limit-label">Progress</span>
          <span class="rs-limit-meta">{progress_meta(@run_state, @run)}</span>
          <span :if={eta = eta_label(@run_ready?, @run)} class="rs-limit-meta">{eta}</span>
        </div>
        <div class="rs-meter"><i class={meter_class(run_percent(@run))} style={"width:#{run_percent(@run)}%"}></i></div>
      </div>
    </section>
    """
  end

  attr(:card, :map, required: true)
  attr(:usage_ready?, :boolean, required: true)
  attr(:now, :any, required: true)

  defp vendor_card(assigns) do
    assigns =
      assigns
      |> assign(:usage, provider_usage(assigns.card))
      |> assign(:windows, meter_windows(assigns.card))
      |> assign(:show_spend?, provider_spend?(assigns.card))
      |> assign(:token_count, token_count(assigns.usage_ready?, provider_usage(assigns.card)))

    ~H"""
    <div class="rs-block">
      <div class="rs-head">
        <img class="rs-logo" src={provider_logo(@card.provider)} alt="" aria-hidden="true" />
        <span class="rs-name">{@card.provider_label}</span>
        <div class="rs-head-stats">
          <div :if={@token_count} class="rs-stat">
            <span class="rs-stat-label">Tokens</span>
            <span class="rs-stat-val">
              {@token_count}
              <%!-- The per-provider token glyph sits to the right of the count.
                    Decorative: the label already says Tokens. --%>
              <img class="rs-token-ic" src={provider_token_icon(@card.provider)} alt="" aria-hidden="true" />
            </span>
          </div>
          <%!-- An unknown token count hides its label and the "N/A" text: a bare
                "Tokens N/A" row is noise. The token glyph remains, alone, at the
                top right of the card at logo size, so the card keeps its shape. --%>
          <img :if={is_nil(@token_count)} class="rs-logo rs-token-na" src={provider_token_icon(@card.provider)} alt="" aria-hidden="true" />
          <div :if={@show_spend?} class="rs-stat">
            <span class="rs-stat-label">Spend</span>
            <span class="rs-stat-val rs-stat-spend">{if @usage_ready?, do: money(@usage), else: "N/A"}</span>
          </div>
        </div>
      </div>
      <div class="rs-limits">
        <div :if={@windows == [] and durable_record(@card)} class="rs-limit">
          <div class="rs-limit-top">
            <span class="rs-limit-label">Limits</span>
            <span class="rs-limit-meta">{durable_meta(durable_record(@card), @now)}</span>
          </div>
          <div class="rs-meter"><i class={meter_class(durable_percent(durable_record(@card)))} style={"width:#{durable_percent(durable_record(@card))}%"}></i></div>
        </div>
        <div :if={@windows == [] and is_nil(durable_record(@card))} class="rs-limit">
          <div class="rs-limit-top">
            <span class="rs-limit-label">Limits</span>
            <span class="rs-limit-meta">{provider_status(@card)}</span>
          </div>
          <div class="rs-meter"><i style="width:0%"></i></div>
        </div>
        <div :for={window <- @windows} class="rs-limit">
          <div class="rs-limit-top">
            <span class="rs-limit-label">{window_label(window, @windows)}</span>
            <span class="rs-limit-meta">{window_meta(window, @now)}</span>
          </div>
          <div class="rs-meter"><i class={meter_class(meter_percent(window))} style={"width:#{meter_percent(window)}%"}></i></div>
        </div>
      </div>
    </div>
    """
  end

  # --- compressed (>4 panes) -----------------------------------------------

  # The compressed strip is one pane holding two named groups. The grouping is
  # rendered, not implied by order: an operator scanning for "is my model
  # provider out of quota" should not have to know that the GitHub row happens
  # to sort last.
  attr(:cards, :list, required: true)
  attr(:github_quota, :map, required: true)
  attr(:now, :any, required: true)

  defp compressed_meters(assigns) do
    assigns =
      assigns
      |> assign(:agent_rows, Enum.map(assigns.cards, &compressed_provider_row(&1, assigns.now)))
      |> assign(:other_rows, [compressed_github_row(assigns.github_quota, assigns.now)])

    ~H"""
    <div class="rs-block rs-compressed">
      <.compressed_group title="Agent APIs" rows={@agent_rows} />
      <.compressed_group title="Other" rows={@other_rows} />
    </div>
    """
  end

  attr(:title, :string, required: true)
  attr(:rows, :list, required: true)

  defp compressed_group(assigns) do
    ~H"""
    <div class="rs-group">
      <div class="rs-group-head">
        <span class="rs-group-title">{@title}</span>
        <span class="rs-group-count">{provider_count_label(length(@rows))}</span>
      </div>
      <div class="rs-group-rows">
        <div :for={row <- @rows} class="rs-row">
          <div class="rs-row-id">
            <img :if={row.logo} class="rs-logo" src={row.logo} alt="" aria-hidden="true" />
            <span :if={is_nil(row.logo)} class="rs-logo rs-github-logo" aria-hidden="true">GH</span>
            <span class="rs-row-name">{row.name}</span>
          </div>
          <div class="rs-row-meters">
            <div :for={line <- row.lines} class="rs-row-meter">
              <span class="rs-limit-label">{line.label}</span>
              <div :if={line.percent} class="rs-meter"><i class={line.class} style={"width:#{line.percent}%"}></i></div>
              <span :if={is_nil(line.percent)} class="rs-meter rs-meter-none"></span>
              <span class="rs-limit-meta">{line.meta}</span>
            </div>
          </div>
          <%!-- The state chip is the compressed row's staleness signal. A row
                that lost it would read a last-known-good or unavailable value
                as a live one (the failure mode of issue #1564), so it renders
                for every row, including the healthy ones. --%>
          <span class={["rs-state", row.state_class]}>{row.state_label}</span>
        </div>
      </div>
    </div>
    """
  end

  defp provider_count_label(1), do: "1 provider"
  defp provider_count_label(count), do: "#{count} providers"

  defp compressed_provider_row(card, now) do
    {state_label, state_class} = compressed_state(card)

    %{
      logo: provider_logo(card.provider),
      name: card.provider_label,
      lines: compressed_provider_lines(card, now),
      state_label: state_label,
      state_class: state_class
    }
  end

  defp compressed_provider_lines(card, now) do
    case meter_windows(card) do
      [] -> [compressed_fallback_line(card, now)]
      windows -> Enum.map(windows, &compressed_window_line(&1, windows, now))
    end
  end

  defp compressed_window_line(window, windows, now) do
    percent = meter_percent(window)

    %{
      label: window_label(window, windows),
      percent: percent,
      class: meter_class(percent),
      meta: compressed_window_meta(window, now)
    }
  end

  defp compressed_fallback_line(card, now) do
    case durable_record(card) do
      # No live window and no durable record is not a zero-consumed reading —
      # it is the absence of one. The line carries no bar at all rather than an
      # empty track, which would read exactly like a healthy 0%.
      nil ->
        %{label: "Limits", percent: nil, class: "", meta: provider_status(card)}

      record ->
        %{label: "Limits", percent: durable_percent(record), class: meter_class(durable_percent(record)), meta: durable_meta(record, now)}
    end
  end

  # The compressed row trades the card's headroom for a wider meter line, so
  # the line carries the counts the card left implicit: an exact
  # remaining-of-limit reading where the window reports one, and the percentage
  # form otherwise. A window the probe marked stale says so here — a stale
  # remaining count and a live one must never render identically.
  defp compressed_window_meta(window, now) do
    meta = compressed_window_base_meta(window, now)

    # `window_meta/2` already appends its own stale clause for a credit balance
    # past its freshness horizon, so the probe-reported window freshness is only
    # added when the meta does not already say it.
    if Map.get(window, :freshness) == :stale and not String.contains?(meta, "stale") do
      meta <> " (stale)"
    else
      meta
    end
  end

  defp compressed_window_base_meta(%{kind: kind, remaining: remaining, limit: limit} = window, now)
       when kind != :credit and is_number(remaining) and is_number(limit) do
    "#{remaining}/#{limit} left · #{reset_text(Map.get(window, :resets_at), now)}"
  end

  defp compressed_window_base_meta(window, now), do: window_meta(window, now)

  defp compressed_github_row(quota, now) do
    windows = github_windows(quota)
    backoffs = github_backoffs(quota)
    {state_label, state_class} = compressed_github_state(windows, backoffs)

    %{
      logo: nil,
      name: "GitHub API",
      lines: compressed_github_lines(windows, backoffs, now) ++ compressed_coverage_lines(quota),
      state_label: state_label,
      state_class: state_class
    }
  end

  defp compressed_github_lines([], backoffs, now) do
    # No window yet is the absence of a reading, not a quota observed to be
    # untouched. It draws the hollow track rather than a full-width empty one,
    # so it cannot be read as a healthy 0% consumed.
    [%{label: "Quota", percent: nil, class: "", meta: "Awaiting GitHub response"}] ++
      compressed_backoff_lines(backoffs, now)
  end

  defp compressed_github_lines(windows, backoffs, now) do
    Enum.map(windows, fn window ->
      %{
        label: github_window_label(window),
        percent: window.used_percent,
        class: meter_class(window.used_percent, 90),
        meta: github_window_meta(window, now)
      }
    end) ++ compressed_backoff_lines(backoffs, now)
  end

  # The compressed strip carries the coverage caveat too: the grouped table
  # shows GitHub's meters, and a meter with no statement of how much of it Aiur
  # can explain is the surface #1805 reported.
  #
  # It carries the short form, though. This row's meta track is a fixed width
  # that does not wrap, so the full sentence — leader, its share, coverage and
  # the estimation caveat — pushed the whole table past the viewport and broke
  # the compressed row's no-horizontal-scroll guarantee. The leader itself is
  # not compressed at all; the compressed row never named one, and the fraction
  # is the part that keeps the meter honest.
  defp compressed_coverage_lines(quota) do
    case github_coverage(quota) do
      nil -> []
      coverage -> [%{label: "Attributed", percent: nil, class: "", meta: compressed_coverage_meta(coverage)}]
    end
  end

  defp compressed_coverage_meta(coverage) do
    named = Map.get(coverage, :named_fraction) || 0.0

    "#{percent_text(named)} of #{Map.get(coverage, :spend, 0)} spent"
  end

  # A backoff is a live stoppage rather than a measured window, so it renders
  # as a note line with no bar: a fabricated meter width would be the kind of
  # confident wrong number this strip must not invent.
  defp compressed_backoff_lines(backoffs, _now) do
    Enum.map(backoffs, fn backoff ->
      %{
        label: "#{github_window_label(backoff)} backoff",
        percent: nil,
        class: "",
        meta: "Secondary limit · #{backoff.seconds_remaining}s left"
      }
    end)
  end

  defp compressed_github_state([], _backoffs), do: {"Awaiting", "is-nodata"}
  defp compressed_github_state(_windows, [_ | _]), do: {"Backoff", "is-partial"}
  defp compressed_github_state(_windows, _backoffs), do: {"Observed", "is-healthy"}

  # A card whose only standing is the durable dispatch ledger is stale by
  # construction, whatever its live state says.
  defp compressed_state(card) do
    case durable_record(card) do
      nil -> state_chip(Map.get(card, :state), Map.get(card, :status_label))
      _record -> {"Stale", "is-stale"}
    end
  end

  defp state_chip(:healthy, _label), do: {"Healthy", "is-healthy"}
  defp state_chip(:partial, _label), do: {"Partial", "is-partial"}
  defp state_chip(:stale, _label), do: {"Stale", "is-stale"}
  defp state_chip(:loading, _label), do: {"Loading…", "is-nodata"}
  defp state_chip(:unknown, _label), do: {"No data", "is-nodata"}
  defp state_chip(:error, _label), do: {"Provider error", "is-unavailable"}
  defp state_chip(:unavailable, _label), do: {"Unavailable", "is-unavailable"}
  defp state_chip(_state, label) when is_binary(label) and label != "", do: {label, "is-nodata"}
  defp state_chip(_state, _label), do: {"N/A", "is-nodata"}

  defp provider_cards(usage, %{state: :authorized, cards: cards}) when is_list(cards) do
    cards
    |> Enum.map(fn card ->
      card
      |> Map.put(:usage, get_in(usage, [:providers, card.provider]))
      |> put_durable_observation()
    end)
    |> keyed_cards()
    |> order_cards()
  end

  defp provider_cards(_usage, _meters) do
    CodingAgent.provider_families()
    |> Enum.map(fn provider ->
      %{provider: provider, provider_label: provider_label(provider), status_label: "N/A", windows: []}
    end)
    |> keyed_cards()
    |> order_cards()
  end

  defp github_windows(%{windows: windows}) when is_map(windows) do
    ~w(core graphql)
    |> Enum.map(&Map.get(windows, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp github_windows(_quota), do: []

  defp github_backoffs(%{backoffs: backoffs}) when is_list(backoffs), do: backoffs
  defp github_backoffs(_quota), do: []

  defp github_attribution(%{attribution: attribution}) when is_list(attribution) and attribution != [] do
    Enum.reduce(attribution, %{reads: 0, writes: 0}, fn entry, totals ->
      %{reads: totals.reads + Map.get(entry, :reads, 0), writes: totals.writes + Map.get(entry, :writes, 0)}
    end)
  end

  defp github_attribution(_quota), do: nil

  # Ranked by cost, not by call count. GraphQL bills points: one catalog query
  # can cost 26 while a hundred reads cost one each, so a request-count ranking
  # names a leader that is not burning the budget (#1805).
  defp github_top_consumer(%{attribution: attribution}) when is_list(attribution) do
    attribution
    |> Enum.reject(&(Map.get(&1, :consumer) == "unattributed"))
    |> Enum.max_by(&{consumer_cost(&1), Map.get(&1, :total, 0)}, fn -> nil end)
  end

  defp github_top_consumer(_quota), do: nil

  defp consumer_cost(entry), do: Map.get(entry, :cost) || Map.get(entry, :total, 0)

  defp github_coverage(%{coverage: %{spend: spend} = coverage}) when is_integer(spend) and spend > 0, do: coverage
  defp github_coverage(_quota), do: nil

  defp github_top_consumer_meta(consumer, coverage) do
    cost = consumer_cost(consumer)
    base = "#{consumer.consumer} · #{cost} #{unit(cost)}"

    case coverage do
      %{spend: spend} when is_integer(spend) and spend > 0 -> "#{base} · #{percent_text(cost / spend)} of window spend"
      _unknown -> base
    end
  end

  # Two numbers an operator can act on: how much of the window's real spend the
  # ranking accounts for, and how much of it Aiur observed at all. The gap
  # between them is traffic Aiur saw but could not tie to a ticket; what is
  # missing from both is traffic it never saw.
  defp github_coverage_meta(coverage) do
    named = Map.get(coverage, :named_fraction) || 0.0
    observed = Map.get(coverage, :fraction) || 0.0
    spend = Map.get(coverage, :spend, 0)

    meta = "#{percent_text(named)} of #{spend} spent this window · #{percent_text(observed)} observed"

    if Map.get(coverage, :estimated?), do: meta <> " · GraphQL cost partly estimated", else: meta
  end

  defp unit(1), do: "point"
  defp unit(_cost), do: "points"

  # Sub-1% coverage is the whole finding, so it must not round to "0%".
  defp percent_text(fraction) when is_float(fraction) or is_integer(fraction) do
    percent = fraction * 100.0

    cond do
      percent >= 10 -> "#{round(percent)}%"
      percent >= 1 -> "#{Float.round(percent, 1)}%"
      percent > 0 -> "#{Float.round(percent, 2)}%"
      true -> "0%"
    end
  end

  defp percent_text(_fraction), do: "0%"

  defp github_window_label(%{resource: "graphql"}), do: "GraphQL"
  defp github_window_label(%{resource: resource}), do: String.capitalize(resource)

  defp github_window_meta(window, now) do
    "#{window.remaining}/#{window.limit} left · #{reset_text(window.reset_at, now)}"
  end

  # A provider card only occupies strip space when the provider is actually
  # connected. OpenAI-compatible providers gate on their configured credential
  # env — `api_key_env` / `management_api_key_env` resolving to a non-empty
  # value, the same "keyed" notion the meter probe uses. App-server providers
  # (codex, claude) authenticate by session rather than an env key, so they
  # always show.
  defp keyed_cards(cards), do: Enum.filter(cards, &provider_keyed?(&1.provider))

  defp provider_keyed?(provider) do
    case get_in(CodingAgent.backends(), [Atom.to_string(provider), :openai_compat]) do
      %{} = compat ->
        case Map.get(compat, :management_api_key_env) || Map.get(compat, :api_key_env) do
          env when is_binary(env) and env != "" -> env_present?(env)
          _ -> false
        end

      _ ->
        true
    end
  end

  defp env_present?(env) do
    case System.get_env(env) do
      value when is_binary(value) and value != "" -> true
      _ -> false
    end
  end

  # DeepSeek leads the strip: it takes the position the Summary block used to
  # occupy, so it sorts ahead of the registry card order while the rest keep
  # their relative order.
  defp order_cards(cards) do
    cards
    |> Enum.with_index()
    |> Enum.sort_by(fn {card, index} -> {lead_rank(card.provider), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp lead_rank(@lead_provider), do: 0
  defp lead_rank(_provider), do: 1

  # A provider that has never been observed this boot reads `:unknown` — a bare
  # "N/A" — even when the durable dispatch-limits ledger holds its last real
  # standing (e.g. Codex at 100/100 from the previous boot, now unable to open
  # a probe session on an exhausted quota). Attach that durable record so the
  # card can render a visibly-stale last-known value instead of an empty one.
  defp put_durable_observation(%{state: :unknown} = card) do
    case durable_observation(card.provider) do
      nil -> card
      observation -> Map.put(card, :durable_observation, observation)
    end
  end

  defp put_durable_observation(card), do: card

  # The card's attached durable record, when present.
  defp durable_record(%{durable_observation: observation}), do: observation
  defp durable_record(_card), do: nil

  # The durable record is keyed by backend family and carries the last used/limit
  # per window plus an observed timestamp. `ModelAvailability` is a public read
  # API; the web layer simply never reached it before. The record's windows are
  # the dispatch buckets (`hourly`/`weekly`/`monthly`); the governing one is the
  # most-used, which is what limits whether new work may start.
  defp durable_observation(provider) do
    with %{"backends" => backends} <- ModelAvailability.load(),
         %{} = entry when map_size(entry) > 0 <- Map.get(backends, Atom.to_string(provider)),
         %{percent: percent} <- durable_percent_entry(entry) do
      %{
        percent: percent,
        observed_at: parse_observed_at(Map.get(entry, "observed_at"))
      }
    else
      _ -> nil
    end
  end

  defp parse_observed_at(%DateTime{} = value), do: value

  defp parse_observed_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_observed_at(_value), do: nil

  defp durable_percent_entry(entry) do
    entry
    |> Map.take(@durable_windows)
    |> Enum.map(fn {_window, %{"used" => used, "limit" => limit}} when is_number(used) and is_number(limit) and limit > 0 ->
      %{percent: min(round(used / limit * 100), 100)}
    end)
    |> Enum.max_by(& &1.percent, fn -> nil end)
  end

  defp provider_usage(%{usage: usage}), do: usage
  defp provider_usage(_card), do: nil

  defp provider_spend?(%{auth_mode: %{value: :api_key}}), do: true
  defp provider_spend?(_card), do: false

  # An unknown-identity meter used to render no label at all above a 0%-wide
  # bar, which reads as a real "0% consumed". Name it instead. A card that has
  # a durable observation renders that from the template (with staleness); the
  # status clause below is only reached for a card with nothing durable either.
  defp provider_status(%{state: :unknown}), do: "N/A"
  defp provider_status(%{status_label: label}) when is_binary(label) and label != "", do: label
  defp provider_status(_card), do: "N/A"

  # Codex reports an account-wide limit alongside per-model ones
  # (`codex:primary` vs `codex_bengalfox:primary`). Only the account-wide bucket
  # is shown: it is the one that governs whether work can proceed at all, and
  # listing a row per model turns a glanceable card into a table. Per-model
  # limits remain in the projection for anything that wants them.
  #
  # Credit-based providers (a prepaid balance) publish no rate-limit percentage,
  # only a dollar window. Those are shown too — a prepaid balance is the honest
  # standing for a provider like DeepSeek, and dropping it makes the card read
  # as if the provider had no limit at all.
  #
  # The local-concurrency gauge is a measured in-flight window: at zero requests
  # it reads a truthful "0%" but is pure noise, so it only appears once there is
  # something in flight to show.
  defp meter_windows(%{windows: windows} = card) when is_list(windows) do
    rate_limits = Enum.filter(windows, &(&1.kind == :rate_limit and visible_rate_limit?(&1)))
    credits = Enum.filter(windows, &(&1.kind == :credit))

    shown_rate_limits =
      case Enum.filter(rate_limits, &account_wide?(&1, Map.get(card, :provider))) do
        [] -> Enum.take(rate_limits, 2)
        account_wide -> Enum.take(account_wide, 2)
      end

    Enum.take(shown_rate_limits, 2) ++ Enum.take(credits, 1)
  end

  defp meter_windows(_card), do: []

  # The local-concurrency gauge is a measured in-flight window: it reads a
  # truthful "0%" at zero requests but is pure noise, so it only appears once
  # there is something in flight to show. The decision keys on the *used*
  # value (the in-flight count), not the rounded meter percent — a few requests
  # against a large limit round to 0% but are still real activity.
  defp visible_rate_limit?(%{limit_id: "local-concurrency"} = window), do: concurrency_used(window) > 0
  defp visible_rate_limit?(_window), do: true

  defp concurrency_used(%{used: used}) when is_number(used), do: used
  defp concurrency_used(%{used_percent: percent}) when is_number(percent), do: percent
  defp concurrency_used(_window), do: 0

  # Account-wide windows carry the bare provider scope; a per-model one suffixes
  # it with the model's codename.
  defp account_wide?(window, provider) do
    case Map.get(window, :limit_id) do
      nil -> true
      limit_id -> limit_id |> to_string() |> String.split(":") |> List.first() == to_string(provider)
    end
  end

  # Codex reports several limits that share a `name`: an account-wide one and a
  # per-model one both come through as "Primary", differing only in the scope
  # prefix of their id (`codex:primary` vs `codex_bengalfox:primary`). They are
  # genuinely different limits — they read alike only while both sit unused —
  # so they are both shown, and the scope is what distinguishes them.
  defp window_label(window, windows) do
    name = Map.get(window, :name, "Limit")

    if Enum.count(windows, &(Map.get(&1, :name) == name)) > 1 do
      window |> Map.get(:limit_id) |> window_scope() || name
    else
      name
    end
  end

  # `limit_id` is "<scope>:<name>"; the scope is the part worth showing when the
  # name cannot tell two windows apart.
  defp window_scope(nil), do: nil

  defp window_scope(limit_id) do
    limit_id
    |> to_string()
    |> String.split(":")
    |> List.first()
    |> String.replace("_", " ")
  end

  # Whether the remaining ticket count is a known value at all, as opposed to
  # not being known yet (loading, unavailable).
  defp remaining_count(state, run) when state in [:ready, :stale], do: Map.get(run[:counts] || %{}, :remaining, 0)
  defp remaining_count(:empty, _run), do: 0
  defp remaining_count(_state, _run), do: nil

  defp progress_meta(state, run) when state in [:ready, :stale], do: run.elapsed.label <> " elapsed"
  defp progress_meta(:empty, _run), do: "0% · no active run"
  defp progress_meta(_state, _run), do: "N/A"

  defp run_percent(%{progress: %{kind: :exact, percent: percent}}) when is_integer(percent), do: percent
  defp run_percent(%{progress: %{kind: :lower_bound, lower_bound_percent: percent}}) when is_integer(percent), do: percent
  defp run_percent(_run), do: 0

  defp eta_label(true, %{eta: %{reason: :zero_eligible_weight}}), do: nil
  defp eta_label(true, %{eta: %{label: label}}) when is_binary(label) and label != "", do: label
  defp eta_label(_ready?, _run), do: nil

  defp provider_spend_total(cards) do
    amounts =
      cards
      |> Enum.filter(&provider_spend?/1)
      |> Enum.flat_map(fn card -> get_in(card, [:usage, :api_equivalent]) || [] end)

    case amounts do
      [] -> nil
      amounts -> money_list(sum_by_currency(amounts))
    end
  end

  defp sum_by_currency(amounts) do
    amounts
    |> Enum.reduce(%{}, fn %{currency: currency, amount: amount}, totals ->
      Map.update(totals, currency, Decimal.new(amount), &Decimal.add(&1, Decimal.new(amount)))
    end)
    |> Enum.map(fn {currency, amount} -> %{currency: currency, amount: Decimal.to_string(amount, :normal)} end)
    |> Enum.sort_by(& &1.currency)
  end

  # A token count is only worth a labelled row when it is a real number; an
  # unknown count degrades to `nil` so the template drops the label and the
  # "N/A" and keeps the glyph alone.
  defp token_count(true, %{tokens: %{total: total}}) when is_integer(total), do: compact_number(total)
  defp token_count(_ready?, _usage), do: nil

  defp money(%{api_equivalent: amounts}), do: money_list(amounts)
  defp money(_usage), do: "N/A"

  defp money_list([%{currency: currency, amount: amount}]), do: currency_amount(currency, amount)
  defp money_list([]), do: "N/A"
  defp money_list(amounts), do: Enum.map_join(amounts, " + ", &currency_amount(&1.currency, &1.amount))

  defp currency_amount("USD", amount), do: "$#{amount}"
  defp currency_amount(currency, amount), do: "#{amount} #{currency}"

  defp compact_number(number) when is_integer(number) and number >= 1_000_000, do: "#{Float.round(number / 1_000_000, 2)}M"
  defp compact_number(number) when is_integer(number) and number >= 1_000, do: "#{Float.round(number / 1_000, 1)}K"
  defp compact_number(number) when is_integer(number), do: Integer.to_string(number)

  # A prepaid-balance window carries its spend percentage as `used_percent`
  # (the probe attaches it only once a durable baseline exists); the bar renders
  # that measured value rather than an empty 0%. Measured rate-limit windows
  # carry the same percentage under `meter.now`. Credit percentages are rounded
  # to one decimal so a float measurement never renders a noisy bar width.
  defp meter_percent(%{kind: :credit, used_percent: percent}) when is_number(percent), do: Float.round(percent, 1)
  defp meter_percent(%{meter: %{kind: :exact, now: percent}}), do: percent
  defp meter_percent(_window), do: 0

  # A bar that is fully consumed reads as critical: the fill turns red so an
  # exhausted window is never mistaken for a healthy one. Credit percentages
  # arrive as floats (e.g. 100.0), so the guard accepts any number at/above 100.
  defp meter_class(percent, warning_threshold \\ nil)
  defp meter_class(percent, _warning_threshold) when is_number(percent) and percent >= 100, do: "is-critical"

  defp meter_class(percent, warning_threshold)
       when is_number(percent) and is_number(warning_threshold) and percent >= warning_threshold,
       do: "is-warning"

  defp meter_class(_percent, _warning_threshold), do: ""

  # A credit window is a dollar balance. When a durable baseline exists the
  # window carries a measured `used_percent` and renders a real spend bar
  # alongside the dollar amount; without a baseline the bar stays empty and the
  # meta carries the balance, so a prepaid provider never reads as a fabricated
  # "0% consumed" (issue #1436).
  #
  # A credit window whose freshness horizon is near or past is no longer a
  # current reading: the meta names its observation time and marks it stale
  # instead of presenting the balance as live (issue #1550).
  defp window_meta(%{kind: :credit, used_percent: used_percent, credits: %{amount: amount}} = window, now)
       when is_number(amount) and is_number(used_percent) do
    base = "#{currency_amount("USD", amount)} · #{format_used_percent(used_percent)}% used"
    if credit_stale?(window, now), do: base <> credit_stale_suffix(window), else: base
  end

  defp window_meta(%{kind: :credit, credits: %{amount: amount}} = window, now) when is_number(amount) do
    if credit_stale?(window, now) do
      "#{currency_amount("USD", amount)}" <> credit_stale_suffix(window)
    else
      "#{currency_amount("USD", amount)} · #{reset_text(window.expires_at, now)}"
    end
  end

  defp window_meta(%{kind: :credit, credits: %{status: status}} = _window, _now) do
    to_string(status) <> " balance"
  end

  defp window_meta(%{meter: %{kind: :exact, now: percent}} = window, now), do: "#{percent}% · #{reset_text(window.resets_at, now)}"
  defp window_meta(window, now), do: "#{window.coverage_label} · #{reset_text(window.resets_at, now)}"

  # The probe stamps a credit window with a 300s freshness horizon
  # (`observed_at + 300s`, the provider endpoint's rate limit). A balance is
  # only a current reading while it sits comfortably inside that horizon; once
  # the final minute has begun — or the horizon has passed — the value must not
  # present as live. The 60s lead keeps a balance observed >4 minutes ago from
  # reading as fresh (the regression this ticket pins).
  @credit_stale_before_expiry_s 60

  defp credit_stale?(%{expires_at: %DateTime{} = expires_at}, %DateTime{} = now) do
    DateTime.compare(expires_at, DateTime.add(now, @credit_stale_before_expiry_s, :second)) != :gt
  end

  defp credit_stale?(_window, _now), do: false

  defp credit_stale_suffix(%{observed_at: %DateTime{} = observed_at}) do
    " · as of #{clock_label(observed_at)} (stale)"
  end

  defp credit_stale_suffix(_window), do: " (stale)"

  defp format_used_percent(percent) when is_number(percent) do
    percent = percent |> max(0) |> min(100)
    rounded = Float.round(percent, 1)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 1)
    end
  end

  # A durable observation renders the last-known standing from the dispatch
  # ledger with an explicit staleness label, so a value that is not a fresh
  # probe is never mistaken for one.
  defp durable_meta(%{percent: percent, observed_at: observed_at}, _now) do
    "#{percent}% used · as of #{clock_label(observed_at)}"
  end

  defp durable_percent(%{percent: percent}), do: percent

  # The ledger stores observations in UTC; render them as such so the "as of"
  # label is never mistaken for a local-time reading.
  defp clock_label(%DateTime{} = observed_at) do
    observed_at = DateTime.shift_zone!(observed_at, "Etc/UTC")
    "#{pad2(observed_at.hour)}:#{pad2(observed_at.minute)} UTC"
  end

  defp clock_label(_observed_at), do: "time unknown"

  defp pad2(value), do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp reset_text(%DateTime{} = reset, %DateTime{} = now) do
    seconds = DateTime.diff(reset, now, :second)
    if seconds > 0, do: "resets in #{duration(seconds)}", else: "reset time passed"
  end

  defp reset_text(_reset, _now), do: "reset unavailable"
  # Days once there are any: a weekly window reading "167h 59m" makes the reader
  # divide to learn it is a week away.
  @seconds_per_day 86_400
  @seconds_per_hour 3_600

  defp duration(seconds) when seconds < @seconds_per_hour, do: "#{max(div(seconds, 60), 1)}m"

  defp duration(seconds) when seconds < @seconds_per_day do
    "#{div(seconds, @seconds_per_hour)}h #{div(rem(seconds, @seconds_per_hour), 60)}m"
  end

  defp duration(seconds) do
    "#{div(seconds, @seconds_per_day)}d #{div(rem(seconds, @seconds_per_day), @seconds_per_hour)}h #{div(rem(seconds, @seconds_per_hour), 60)}m"
  end

  # Each card renders its own registry logo. The ticket's "swap the Codex and
  # Claude logos" premise was verified false on review: `codex-color.svg` is the
  # Codex mark, `claude-symbol.svg` is Anthropic's, and the descriptor lookup
  # below already paired every card with its own logo before this change.
  # Swapping would have inverted a correct pairing, so the strip keeps the
  # truthful mapping (consistent with every other surface that reads the
  # registry).
  defp provider_logo(provider), do: descriptor_field(provider, :logo, "/aiur-logo.png")

  defp provider_token_icon(provider), do: descriptor_field(provider, :token_icon, "/aiur-logo.png")
  defp provider_label(provider), do: descriptor_field(provider, :label, to_string(provider))

  defp descriptor_field(provider, field, fallback) do
    case CodingAgent.provider_descriptor(provider) do
      %{^field => value} -> value
      _ -> fallback
    end
  end
end
