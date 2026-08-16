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

  # GitHub's two primary budgets, in the order they render. They are separate
  # budgets billed in different units on windows that reset at different times,
  # so every figure on the card belongs to exactly one of them.
  @github_resources ~w(core graphql)

  attr(:run, :map, required: true)
  attr(:usage, :map, required: true)
  attr(:meters, :map, required: true)
  attr(:github_quota, :map, default: %{state: :unknown, windows: %{}, attribution: [], coverage: nil, backoffs: []})
  attr(:elevenlabs_quota, :map, default: %{state: :unconfigured, window: nil, failure: nil, observed_at: nil})
  attr(:now, :any, required: true)

  @spec run_summary_strip(map()) :: Phoenix.LiveView.Rendered.t()
  def run_summary_strip(assigns) do
    assigns =
      assigns
      |> assign(:usage_ready?, Map.get(assigns.usage, :state) in [:ready, :partial, :stale])
      |> assign(:cards, provider_cards(assigns.usage, assigns.meters))

    ~H"""
    <section class="run-summary" aria-label="Provider and API usage">
      <.apis_card github_quota={@github_quota} elevenlabs_quota={@elevenlabs_quota} now={@now} />
      <.models_card :if={@cards != []} cards={@cards} usage_ready?={@usage_ready?} now={@now} />
    </section>
    """
  end

  attr(:github_quota, :map, required: true)
  attr(:elevenlabs_quota, :map, required: true)
  attr(:now, :any, required: true)

  # The APIS pane holds one row per non-model API. GitHub always has a row; the
  # ElevenLabs row exists only when an ElevenLabs account is configured, so an
  # operator who never enabled voice input sees no trace of it (an "Unavailable"
  # row for an account that does not exist is a defect, not a status).
  defp apis_card(assigns) do
    assigns =
      assigns
      |> assign(:windows, github_windows(assigns.github_quota))
      |> assign(:backoffs, github_backoffs(assigns.github_quota))
      |> assign(:elevenlabs?, elevenlabs_configured?(assigns.elevenlabs_quota))

    ~H"""
    <div class="rs-block github-quota-card">
      <div class="rs-group-head">
        <span class="rs-group-title">APIS</span>
        <span class="rs-group-count">{api_count_label(@elevenlabs?)}</span>
      </div>
      <div class="rs-apis-rows">
        <div class="rs-api">
          <div class="rs-head">
            <img class="rs-logo rs-github-mark" src="/images/github-mark.svg" alt="" aria-hidden="true" />
            <span class="rs-name">Github</span>
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
                <span class="rs-limit-label" title={github_window_explanation(window)}>{github_window_label(window)}</span>
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
          </div>
        </div>
        <.elevenlabs_api_row :if={@elevenlabs?} quota={@elevenlabs_quota} now={@now} />
      </div>
    </div>
    """
  end

  attr(:quota, :map, required: true)
  attr(:now, :any, required: true)

  # The only figure ElevenLabs publishes is a character/credit quota; the API
  # exposes no dollar balance at all, so none is shown or derived. The label
  # states what the quota is and the tooltip states what it is *not*: speech to
  # text — the Stream Deck voice input this account exists for — bills per minute
  # of audio and is not counted in these characters.
  #
  # This row alone reads *remaining* rather than used, and its bar depletes as
  # credits are spent. That is opposite to every other meter on the page, which
  # is a deliberate, operator-requested direction (see the docs) — the label and
  # the fill agree with each other, which is what keeps it readable.
  defp elevenlabs_api_row(assigns) do
    assigns = assign(assigns, :window, Map.get(assigns.quota, :window))

    ~H"""
    <div class="rs-api rs-elevenlabs">
      <div class="rs-head">
        <span class="rs-name">ElevenLabs</span>
      </div>
      <div class="rs-limits">
        <div class="rs-limit">
          <div class="rs-limit-top">
            <span class="rs-limit-label" title={elevenlabs_explanation()}>Credits remaining</span>
            <span class="rs-limit-meta">{elevenlabs_meta(@quota, @now)}</span>
          </div>
          <%!-- No track outside the observed state: an empty bar under a
                "remaining" label reads as an exhausted account, which is exactly
                what an unread quota is not known to be. --%>
          <div :if={is_number(elevenlabs_remaining_percent(@window))} class="rs-meter">
            <i
              class={remaining_meter_class(elevenlabs_remaining_percent(@window))}
              style={"width:#{elevenlabs_remaining_percent(@window)}%"}
            >
            </i>
          </div>
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
          <span class="rs-limit-meta">{progress_label(@run)}</span>
          <span class="rs-limit-meta">{progress_meta(@run_state, @run)}</span>
          <span :if={eta = eta_label(@run_ready?, @run)} class="rs-limit-meta">{eta}</span>
        </div>
        <div class="rs-meter"><i class={meter_class(run_percent(@run))} style={"width:#{run_percent(@run)}%"}></i></div>
      </div>
    </section>
    """
  end

  attr(:cards, :list, required: true)
  attr(:usage_ready?, :boolean, required: true)
  attr(:now, :any, required: true)

  defp models_card(assigns) do
    ~H"""
    <div class="rs-block rs-models" aria-label="Model providers">
      <div class="rs-group-head">
        <span class="rs-group-title">Models</span>
        <span class="rs-group-count">{model_count_label(length(@cards))}</span>
      </div>
      <div class="rs-models-rows">
        <.model_row :for={card <- @cards} card={card} usage_ready?={@usage_ready?} now={@now} />
      </div>
    </div>
    """
  end

  attr(:card, :map, required: true)
  attr(:usage_ready?, :boolean, required: true)
  attr(:now, :any, required: true)

  defp model_row(assigns) do
    assigns =
      assigns
      |> assign(:usage, provider_usage(assigns.card))
      |> assign(:windows, meter_windows(assigns.card))
      |> assign(:show_spend?, provider_spend?(assigns.card))
      |> assign(:token_count, token_count(assigns.usage_ready?, provider_usage(assigns.card)))
      |> assign(:token_glyph?, token_glyph?(assigns.card.provider))
      |> assign(:standing, model_standing(assigns.card))

    ~H"""
    <div class="rs-model">
      <div class="rs-head">
        <%!-- One logo per row, on the far left, so every row starts with the same landmark. Decorative: the name beside it already identifies the provider. --%>
        <img class="rs-logo" src={provider_logo(@card.provider)} alt="" aria-hidden="true" />
        <span class="rs-name">{@card.provider_label}</span>
        <div class="rs-head-stats">
          <div :if={@token_count} class="rs-stat">
            <span class="rs-stat-label">Tokens</span>
            <span class="rs-stat-val">
              {@token_count}
              <%!-- The per-provider token glyph sits to the right of the count. Decorative: the label already says Tokens. --%>
              <img :if={@token_glyph?} class="rs-token-ic" src={provider_token_icon(@card.provider)} alt="" aria-hidden="true" />
            </span>
          </div>
          <%!-- An unknown token count hides its label and the "N/A" text. On the two rows that carry a token glyph it remains, alone, so the card keeps its shape; the rest simply lose the stat. --%>
          <img :if={@token_glyph? and is_nil(@token_count)} class="rs-logo rs-token-na" src={provider_token_icon(@card.provider)} alt="" aria-hidden="true" />
        </div>
        <%!-- The spend figure closes the row on the right. --%>
        <div :if={@show_spend?} class="rs-stat rs-spend">
          <span class="rs-stat-label">Spend</span>
          <span class="rs-stat-val rs-stat-spend">{if @usage_ready?, do: money(@usage), else: "N/A"}</span>
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
            <span class="rs-limit-meta">{model_window_meta(window, @now, @standing)}</span>
          </div>
          <div class="rs-meter"><i class={meter_class(meter_percent(window))} style={"width:#{meter_percent(window)}%"}></i></div>
        </div>
      </div>
    </div>
    """
  end

  # --- helpers -------------------------------------------------------------

  defp model_count_label(1), do: "1 model"
  defp model_count_label(count), do: "#{count} models"

  # A deliberate two-name list, not a registry lookup. Every provider descriptor
  # defines a token icon, so deriving this would put a second mark on every row
  # — which is the thing the far-left logo was meant to stop. Claude and Codex
  # are the pair the operator actually meters token-by-token, so their glyph
  # earns the right-hand slot; a new provider joins this list by decision, not
  # by shipping an asset.
  @token_glyph_providers [:claude, :codex]

  defp token_glyph?(provider), do: provider in @token_glyph_providers

  # A card can stand at :stale or :partial while its retained windows are still
  # stamped fresh — an adapter failure, or repeated probe failures over the last
  # known-good values (`ProviderMeterProjection.health_state/3`). The row's head
  # chip used to name that; with the chip gone the qualifier has to ride on the
  # meta line, or those readings render as live ones — the confusion issue #1564
  # exists to prevent.
  defp model_standing(%{state: :stale}), do: "stale"
  defp model_standing(%{state: :partial}), do: "partial"
  defp model_standing(_card), do: nil

  # `window_meta/2` already appends its own stale clause for a credit balance
  # past its freshness horizon, and a stale-stamped window says so itself, so
  # neither qualifier is added when the meta already carries the word.
  defp model_window_meta(window, now, standing) do
    meta = window_meta(window, now)

    meta =
      if Map.get(window, :freshness) == :stale and not String.contains?(meta, "stale") do
        meta <> " (stale)"
      else
        meta
      end

    if standing && not String.contains?(meta, standing), do: meta <> " (#{standing})", else: meta
  end

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

  defp api_count_label(true), do: "2 APIs"
  defp api_count_label(_elevenlabs?), do: "1 API"

  # An unconfigured account is not an API this deployment has: the row is absent
  # entirely. Every other standing — awaiting a first answer, observed, or a
  # failed read against a key that *is* configured — keeps the row, because each
  # of those is a fact about a real account.
  defp elevenlabs_configured?(%{state: :unconfigured}), do: false
  defp elevenlabs_configured?(%{state: state}) when state in [:unknown, :observed, :failed], do: true
  defp elevenlabs_configured?(_quota), do: false

  defp elevenlabs_remaining_percent(%{remaining_percent: percent}) when is_number(percent), do: percent
  defp elevenlabs_remaining_percent(_window), do: nil

  defp elevenlabs_explanation do
    "ElevenLabs account credit quota (characters). Speech-to-text is billed per minute of audio and is not counted here. ElevenLabs publishes no dollar balance."
  end

  # Credits left, then the share they are of the quota, then the reset. The
  # percentage is stated as "left" so the number and the bar beside it can only
  # be read one way.
  defp elevenlabs_meta(%{state: :observed, window: %{} = window}, now) do
    [
      "#{compact_number(window.remaining)}/#{compact_number(window.limit)} credits left",
      elevenlabs_percent_text(window),
      reset_text(window.reset_at, now)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp elevenlabs_meta(%{state: :failed, failure: failure}, _now), do: "Unavailable · #{elevenlabs_failure_label(failure)}"
  defp elevenlabs_meta(_quota, _now), do: "Awaiting ElevenLabs response"

  defp elevenlabs_percent_text(%{remaining_percent: percent}) when is_number(percent), do: "#{format_used_percent(percent)}% left"
  defp elevenlabs_percent_text(_window), do: nil

  # Named reasons only, and never the credential: a failure line is one of the
  # places a secret leaks into a screenshot.
  defp elevenlabs_failure_label(:authentication), do: "the API key was rejected"
  defp elevenlabs_failure_label(:rate_limited), do: "rate limited by ElevenLabs"
  defp elevenlabs_failure_label(:provider_error), do: "ElevenLabs returned an error"
  defp elevenlabs_failure_label(:transport), do: "ElevenLabs could not be reached"
  defp elevenlabs_failure_label(:malformed), do: "the response could not be read"
  defp elevenlabs_failure_label(_failure), do: "the quota could not be read"

  # A remaining-direction bar warns in the opposite direction to a used one: it
  # is alarming when it is *low*, so the used-percentage thresholds must not be
  # reused here.
  defp remaining_meter_class(percent) when is_number(percent) and percent <= 0, do: "is-critical"
  defp remaining_meter_class(percent) when is_number(percent) and percent <= 10, do: "is-warning"
  defp remaining_meter_class(_percent), do: ""

  defp github_windows(%{windows: windows}) when is_map(windows) do
    @github_resources
    |> Enum.map(&Map.get(windows, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp github_windows(_quota), do: []

  defp github_backoffs(%{backoffs: backoffs}) when is_list(backoffs), do: backoffs
  defp github_backoffs(_quota), do: []

  defp github_window_label(%{resource: resource}), do: github_resource_label(resource)

  defp github_resource_label("graphql"), do: "GraphQL"
  defp github_resource_label(resource), do: String.capitalize(resource)

  # GitHub's two budgets bill in different units; the popover names what each
  # window actually meters so "Core"/"GraphQL" are never read as the same thing.
  defp github_window_explanation(%{resource: "core"}), do: "REST request budget"
  defp github_window_explanation(%{resource: "graphql"}), do: "GraphQL point budget"
  defp github_window_explanation(_window), do: nil

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
  # Local concurrency is an instantaneous count owned by this Aiur process, not
  # a provider-reported quota. Retaining it in the provider projection turns it
  # into a stale pseudo-limit, so provider cards never render that window. Live
  # consumers such as the CLI and TUI can still use the underlying measurement.
  defp meter_windows(%{windows: windows} = card) when is_list(windows) do
    rate_limits = Enum.filter(windows, &(&1.kind == :rate_limit and visible_rate_limit?(&1)))
    credits = Enum.filter(windows, &(&1.kind == :credit and show_credit_window?(card, &1)))

    shown_rate_limits =
      case Enum.filter(rate_limits, &account_wide?(&1, Map.get(card, :provider))) do
        [] -> Enum.take(rate_limits, 2)
        account_wide -> Enum.take(account_wide, 2)
      end

    Enum.take(shown_rate_limits, 2) ++ Enum.take(credits, 1)
  end

  defp meter_windows(_card), do: []

  # Codex reports `hasCredits`/`unlimited`/`rateLimitResetCredits` facts, not a
  # prepaid dollar balance. Rendering them as a "Credits … balance" row with a
  # meter implies a spendable balance that does not exist, so the codex card
  # drops its credit windows entirely.
  defp show_credit_window?(%{provider: :codex}, _window), do: false
  defp show_credit_window?(_card, _window), do: true

  defp visible_rate_limit?(%{limit_id: "local-concurrency"}), do: false
  defp visible_rate_limit?(_window), do: true

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

  defp progress_label(%{progress: %{kind: :exact, percent: percent}}) when is_integer(percent),
    do: "#{percent}% complete"

  defp progress_label(%{
         progress: %{
           kind: :partial,
           display_percent_label: percent,
           current_members_label: members,
           fact_status_label: status
         }
       }),
       do: "#{percent} · #{members} · #{status}"

  defp progress_label(%{progress: %{kind: :lower_bound, lower_bound_percent: percent}}) when is_integer(percent),
    do: "At least #{percent}% complete"

  defp progress_label(%{
         progress: %{
           kind: :pending,
           progress_status_label: progress,
           current_members_label: members,
           fact_status_label: status
         }
       }),
       do: "#{progress} · #{members} · #{status}"

  defp progress_label(_run), do: "Progress not computed yet"

  defp run_percent(%{progress: %{kind: :exact, percent: percent}}) when is_integer(percent), do: percent
  defp run_percent(%{progress: %{kind: :lower_bound, lower_bound_percent: percent}}) when is_integer(percent), do: percent
  defp run_percent(%{progress: %{kind: :partial, percent: percent}}) when is_integer(percent), do: percent
  defp run_percent(_run), do: 0

  defp eta_label(true, %{eta: %{reason: :zero_eligible_weight}}), do: nil
  defp eta_label(true, %{eta: %{reason: :unhealthy_weight_facts}}), do: nil
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
  # probe is never mistaken for one. The row's head chip used to carry that
  # word; the label now has to say it here, because the meta line is the only
  # place left that qualifies the number it sits beside (issue #1564).
  defp durable_meta(%{percent: percent, observed_at: observed_at}, _now) do
    "#{percent}% used · as of #{clock_label(observed_at)} (stale)"
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
