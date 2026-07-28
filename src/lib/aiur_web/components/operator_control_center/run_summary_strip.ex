defmodule AiurWeb.OperatorControlCenter.RunSummaryStrip do
  @moduledoc "Compact, truthful current-run and provider-usage summary."

  use Phoenix.Component

  attr(:run, :map, required: true)
  attr(:usage, :map, required: true)
  attr(:meters, :map, required: true)
  attr(:now, :any, required: true)

  @spec run_summary_strip(map()) :: Phoenix.LiveView.Rendered.t()
  def run_summary_strip(assigns) do
    cards = provider_cards(assigns.usage, assigns.meters)

    run_state = Map.get(assigns.run, :state)

    assigns =
      assigns
      |> assign(:run_state, run_state)
      |> assign(:run_ready?, run_state in [:ready, :stale])
      |> assign(:usage_ready?, Map.get(assigns.usage, :state) in [:ready, :partial, :stale])
      |> assign(:cards, cards)
      |> assign(:spend_total, provider_spend_total(cards))

    ~H"""
    <section class="run-summary" aria-label="Run summary and provider usage">
      <div class="rs-block rs-status">
        <div class="rs-head">
          <img class="rs-logo" src="/aiur-logo.png" alt="" aria-hidden="true" />
          <span class="rs-name">Summary</span>
          <div class="rs-head-stats">
            <div class="rs-stat"><span class="rs-stat-label">Tickets</span><span class="rs-stat-val">{count(@run_state, @run, :remaining, "remain")}</span></div>
            <div :if={@spend_total} class="rs-stat"><span class="rs-stat-label">Spend</span><span class="rs-stat-val rs-stat-spend">{@spend_total}</span></div>
          </div>
        </div>
        <div class="rs-progress">
          <div class="rs-limit-top">
            <span class="rs-limit-label">Progress</span>
            <span class="rs-limit-meta">{progress_meta(@run_state, @run)}</span>
            <span :if={eta = eta_label(@run_ready?, @run)} class="rs-limit-meta">{eta}</span>
          </div>
          <div class="rs-meter"><i style={"width:#{run_percent(@run)}%"}></i></div>
        </div>
      </div>

      <.vendor_card :for={card <- @cards} card={card} usage_ready?={@usage_ready?} now={@now} />
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
      |> assign(:windows, rate_windows(assigns.card))
      |> assign(:show_spend?, provider_spend?(assigns.card))

    ~H"""
    <div class="rs-block">
      <div class="rs-head">
        <img class="rs-logo" src={provider_logo(@card.provider)} alt="" aria-hidden="true" />
        <span class="rs-name">{@card.provider_label}</span>
        <div class="rs-head-stats">
          <div class="rs-stat">
            <span class="rs-stat-label">Tokens</span>
            <span class="rs-stat-val">{if @usage_ready?, do: tokens(@usage), else: "N/A"}</span>
          </div>
          <div :if={@show_spend?} class="rs-stat">
            <span class="rs-stat-label">Spend</span>
            <span class="rs-stat-val rs-stat-spend">{if @usage_ready?, do: money(@usage), else: "N/A"}</span>
          </div>
        </div>
      </div>
      <div class="rs-limits">
        <div :if={@windows == []} class="rs-limit">
          <div class="rs-limit-top">
            <span class="rs-limit-label">Limits</span>
            <span class="rs-limit-meta">{provider_status(@card)}</span>
          </div>
          <div class="rs-meter"><i style="width:0%"></i></div>
        </div>
        <div :for={window <- @windows} class="rs-limit">
          <div class="rs-limit-top">
            <span class="rs-limit-label">{window.name}</span>
            <span class="rs-limit-meta">{window_meta(window, @now)}</span>
          </div>
          <div class="rs-meter"><i style={"width:#{meter_percent(window)}%"}></i></div>
        </div>
      </div>
    </div>
    """
  end

  defp provider_cards(usage, %{state: :authorized, cards: cards}) when is_list(cards) do
    Enum.map(cards, fn card ->
      Map.put(card, :usage, get_in(usage, [:providers, card.provider]))
    end)
  end

  defp provider_cards(_usage, _meters) do
    for provider <- [:codex, :claude], do: %{provider: provider, provider_label: provider_label(provider), status_label: "N/A", windows: []}
  end

  defp provider_usage(%{usage: usage}), do: usage
  defp provider_usage(_card), do: nil

  defp provider_spend?(%{auth_mode: %{value: :api_key}}), do: true
  defp provider_spend?(_card), do: false

  # An unknown-identity meter used to render no label at all above a 0%-wide
  # bar, which reads as a real "0% consumed". Name it instead.
  defp provider_status(%{state: :unknown}), do: "N/A"
  defp provider_status(%{status_label: label}) when is_binary(label) and label != "", do: label
  defp provider_status(_card), do: "N/A"

  defp rate_windows(%{windows: windows}) when is_list(windows), do: windows |> Enum.filter(&(&1.kind == :rate_limit)) |> Enum.take(2)
  defp rate_windows(_card), do: []

  defp count(state, %{counts: counts}, key, suffix) when state in [:ready, :stale],
    do: "#{Map.get(counts, key, 0)} #{suffix}"

  # An empty run is a *known* zero, not missing data: the daemon confirmed there
  # is no active run. Naming it "Unavailable" reads as a failure when nothing is
  # wrong. This is not a synthetic zero — the loading and unavailable states,
  # where the count genuinely isn't known, still say so.
  defp count(:empty, _run, _key, suffix), do: "0 #{suffix}"
  defp count(_state, _run, _key, _suffix), do: "N/A"

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

  defp tokens(%{tokens: %{total: total}}), do: compact_number(total)
  defp tokens(_usage), do: "N/A"

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
  defp compact_number(_number), do: "N/A"

  defp meter_percent(%{meter: %{kind: :exact, now: percent}}), do: percent
  defp meter_percent(_window), do: 0

  defp window_meta(%{meter: %{kind: :exact, now: percent}} = window, now), do: "#{percent}% · #{reset_text(window.resets_at, now)}"
  defp window_meta(window, now), do: "#{window.coverage_label} · #{reset_text(window.resets_at, now)}"

  defp reset_text(%DateTime{} = reset, %DateTime{} = now) do
    seconds = DateTime.diff(reset, now, :second)
    if seconds > 0, do: "resets in #{duration(seconds)}", else: "reset time passed"
  end

  defp reset_text(_reset, _now), do: "reset unavailable"
  defp duration(seconds) when seconds < 3_600, do: "#{max(div(seconds, 60), 1)}m"
  defp duration(seconds), do: "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"

  defp provider_logo(:codex), do: "/codex-color.svg"
  defp provider_logo(:claude), do: "/claude-symbol.svg"
  defp provider_logo(_provider), do: "/aiur-logo.png"
  defp provider_label(:codex), do: "Codex"
  defp provider_label(:claude), do: "Claude"
end
