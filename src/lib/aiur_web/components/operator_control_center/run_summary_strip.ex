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
  attr(:now, :any, required: true)

  @spec run_summary_strip(map()) :: Phoenix.LiveView.Rendered.t()
  def run_summary_strip(assigns) do
    assigns =
      assigns
      |> assign(:usage_ready?, Map.get(assigns.usage, :state) in [:ready, :partial, :stale])
      |> assign(:cards, provider_cards(assigns.usage, assigns.meters))

    ~H"""
    <section class="run-summary" aria-label="Provider usage">
      <.vendor_card :for={card <- @cards} card={card} usage_ready?={@usage_ready?} now={@now} />
    </section>
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

  defp meter_percent(%{meter: %{kind: :exact, now: percent}}), do: percent
  defp meter_percent(_window), do: 0

  # A bar that is fully consumed reads as critical: the fill turns red so an
  # exhausted window is never mistaken for a healthy one.
  defp meter_class(percent) when is_integer(percent) and percent >= 100, do: "is-critical"
  defp meter_class(_percent), do: ""

  # A credit window is a dollar balance. When a durable baseline exists the
  # window carries a measured `used_percent` and renders a real spend bar
  # alongside the dollar amount; without a baseline the bar stays empty and the
  # meta carries the balance, so a prepaid provider never reads as a fabricated
  # "0% consumed" (issue #1436).
  defp window_meta(%{kind: :credit, used_percent: used_percent, credits: %{amount: amount}} = _window, _now)
       when is_number(amount) and is_number(used_percent) do
    "#{currency_amount("USD", amount)} · #{format_used_percent(used_percent)}% used"
  end

  defp window_meta(%{kind: :credit, credits: %{amount: amount}} = window, now) when is_number(amount) do
    "#{currency_amount("USD", amount)} · #{reset_text(window.expires_at, now)}"
  end

  defp window_meta(%{kind: :credit, credits: %{status: status}} = _window, _now) do
    to_string(status) <> " balance"
  end

  defp window_meta(%{meter: %{kind: :exact, now: percent}} = window, now), do: "#{percent}% · #{reset_text(window.resets_at, now)}"
  defp window_meta(window, now), do: "#{window.coverage_label} · #{reset_text(window.resets_at, now)}"

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

  # The operator reported the Codex and Claude logo pairing is backwards: the
  # Codex card shows Claude's mark and the Claude card shows Codex's. Swap the
  # two at the point the strip picks the logo so the registry descriptors (and
  # the other surfaces that read them) stay untouched.
  defp provider_logo(:codex), do: descriptor_field(:claude, :logo, "/aiur-logo.png")
  defp provider_logo(:claude), do: descriptor_field(:codex, :logo, "/aiur-logo.png")
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
