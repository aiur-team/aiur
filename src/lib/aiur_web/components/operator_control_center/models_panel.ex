defmodule AiurWeb.OperatorControlCenter.ModelsPanel do
  @moduledoc """
  The MODELS pane of the Units provider strip, drawn to the Claude design
  (`ax-usage` / `ax-ln`): one row per provider, a logo column, then one line per
  meter that reads `[tag] percent bar reset↻`.

  Every line is a fixed grid, so a tag, a percentage, a bar and a reset each own
  one track and can never overlap. A provider with several accounts keeps one
  named line per account (operator directive, #3751) instead of the design's
  split bar. Reset times show the recycle icon and the time; window age,
  freshness and scope live in the line's tooltip, not in repeated text.
  """

  use Phoenix.Component

  import AiurWeb.OperatorControlCenter.MeterStyles, only: [meter_class: 3]

  @seconds_per_day 86_400
  @seconds_per_hour 3_600
  # Tags wider than this truncate with an ellipsis rather than squeeze the bar.
  @max_tag_chars 12

  attr(:cards, :list, required: true)
  attr(:now, :any, required: true)

  @spec models_panel(map()) :: Phoenix.LiveView.Rendered.t()
  def models_panel(assigns) do
    ~H"""
    <div class="rs-block rs-models" aria-label="Model providers">
      <div class="rs-group-head">
        <span class="rs-group-title">Models</span>
        <span class="rs-group-count">{model_count_label(length(@cards))}</span>
      </div>
      <div class="rs-models-rows">
        <.model_row :for={card <- @cards} card={card} now={@now} />
      </div>
    </div>
    """
  end

  attr(:card, :map, required: true)
  attr(:now, :any, required: true)

  defp model_row(assigns) do
    lines = lines(assigns.card, assigns.now)

    assigns =
      assigns
      |> assign(:lines, lines)
      |> assign(:accounts, accounts(assigns.card))
      |> assign(:tag_width, tag_width(lines))

    ~H"""
    <div class="rs-model" data-provider={@card.provider} title={who_title(@card)}>
      <div class="rs-head">
        <img class="rs-logo" src={@card.logo} alt="" aria-hidden="true" />
        <span class="rs-name">{@card.provider_label}</span>
        <span :if={@accounts != []} class="rs-x" title={"#{length(@accounts)} accounts"}>×{length(@accounts)}</span>
      </div>
      <div class="rs-lines" style={@tag_width && "--rs-tag-width: #{@tag_width}ch"}>
        <div
          :for={line <- @lines}
          class={classes(["rs-ln", line.tag && "has-tag", line.stale? && "is-stale"])}
          data-account={line.account}
          title={line.title}
        >
          <span :if={line.tag} class="rs-tg">{line.tag}</span>
          <span class={classes(["rs-pc", tone(line.percent)])}>{percent_text(line.percent)}</span>
          <span
            class={classes(["rs-meter", is_nil(line.percent) && "is-unknown"])}
            role="progressbar"
            aria-label={line.aria_label}
            aria-valuemin="0"
            aria-valuemax="100"
            aria-valuenow={line.percent}
          >
            <i :if={is_number(line.percent) and line.percent > 0} class={meter_class(line.percent, 80, 90)} style={"width:#{bar_width(line.percent)}%"}></i>
          </span>
          <span class="rs-rs">
            <span :if={line.reset}>{line.reset}<em :if={line.window}>/{line.window}</em></span>
            <svg :if={line.reset} viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
              <path d="M20 11a8 8 0 0 0-14.8-3.5M4 13a8 8 0 0 0 14.8 3.5" /><path d="M4 3.5V8h4.5M20 20.5V16h-4.5" />
            </svg>
            <b :if={line.amount} class="rs-usd">{line.amount}</b>
            <span :if={line.note} class="rs-no">{line.note}</span>
          </span>
        </div>
      </div>
    </div>
    """
  end

  # --- lines ---------------------------------------------------------------

  # A provider with named accounts gives each account its own weekly line, so
  # the provider-wide weekly windows would only repeat the worst account. Its
  # remaining windows (the session) take a short tag so every line in the row
  # shares one tag column.
  defp lines(card, now) do
    accounts = accounts(card)
    windows = windows(card, accounts)
    tagged? = accounts != []

    account_lines = Enum.map(accounts, &account_line(&1, now))
    window_lines = Enum.map(windows, &window_line(&1, tagged?, now))

    case account_lines ++ window_lines do
      [] -> [fallback_line(card)]
      lines -> lines
    end
  end

  defp accounts(card), do: get_in(card, [:account_usage, :accounts]) || []

  defp windows(card, []), do: Map.get(card, :windows, [])

  defp windows(card, _accounts) do
    card
    |> Map.get(:windows, [])
    |> Enum.reject(&weekly_window?/1)
  end

  defp weekly_window?(window) do
    window |> Map.get(:limit_id, "") |> to_string() |> String.split(":") |> List.last() |> String.starts_with?("seven_day")
  end

  defp account_line(account, now) do
    percent = if is_number(account.percent), do: account.percent
    reset = percent && reset_label(Map.get(account, :resets_at), now)
    age = if is_integer(account.age_seconds), do: "#{account.age_seconds}s old", else: "age unknown"

    line(%{
      tag: account.name,
      account: account.name,
      percent: percent,
      reset: reset,
      window: reset && "7d",
      note: if(is_nil(percent), do: "unknown"),
      stale?: account.freshness not in [:fresh, "fresh"],
      aria_label: "#{account.name} weekly usage",
      title: "#{account.name} · weekly #{title_percent(percent)} · #{account.freshness}, #{age}#{title_reset(reset)}"
    })
  end

  defp window_line(%{kind: :credit} = window, tagged?, _now) do
    percent = credit_percent(window)
    amount = credit_amount(window)

    line(%{
      tag: if(tagged?, do: "credits"),
      percent: percent,
      amount: amount,
      note: if(is_nil(amount), do: credit_status(window)),
      aria_label: "#{Map.get(window, :name, "Credits")} usage",
      title: "Prepaid credits · #{amount || credit_status(window)}#{if percent, do: " · #{format_percent(percent)}% spent"}"
    })
  end

  defp window_line(window, tagged?, now) do
    percent = window_percent(window)
    reset = percent && reset_label(Map.get(window, :resets_at), now)
    name = Map.get(window, :name, "Limit")

    line(%{
      tag: if(tagged?, do: short_name(name)),
      percent: percent,
      reset: reset,
      window: reset && window_span(window),
      note: if(is_nil(percent), do: "unknown"),
      aria_label: "#{name} usage",
      title: "#{name} · #{title_percent(percent)}#{title_reset(reset)}"
    })
  end

  # A real provider with nothing observed yet keeps one compact line: an
  # explicitly unknown bar (unknown is not zero), or its durable last-known
  # standing when the dispatch-limits ledger holds one.
  defp fallback_line(%{durable_observation: %{percent: percent}}) do
    line(%{percent: percent, aria_label: "Last known usage", title: "Last known usage · #{percent}%"})
  end

  defp fallback_line(card) do
    line(%{note: "unknown", aria_label: "#{card.provider_label} usage", title: "#{card.provider_label} · usage unknown"})
  end

  defp line(fields) do
    Map.merge(%{tag: nil, account: nil, percent: nil, reset: nil, window: nil, amount: nil, note: nil, stale?: false}, fields)
  end

  # --- formatting ----------------------------------------------------------

  defp model_count_label(1), do: "1 model"
  defp model_count_label(count), do: "#{count} models"

  defp who_title(card) do
    [card.provider_label, get_in(card, [:health, :age_label]), unverified(card)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp unverified(card), do: if(get_in(card, [:identity, :state]) == :unverified, do: "Account unverified")

  defp tag_width(lines) do
    case lines |> Enum.map(& &1.tag) |> Enum.reject(&is_nil/1) do
      [] -> nil
      tags -> tags |> Enum.map(&String.length/1) |> Enum.max() |> min(@max_tag_chars) |> max(3)
    end
  end

  defp short_name(name) do
    name |> to_string() |> String.split([" ", "("], trim: true) |> List.first("limit") |> String.downcase()
  end

  defp window_percent(%{used_percent: percent}) when is_number(percent), do: percent
  defp window_percent(%{meter: %{kind: :exact, now: percent}}) when is_number(percent), do: percent
  defp window_percent(_window), do: nil

  defp credit_percent(%{used_percent: percent}) when is_number(percent), do: percent
  defp credit_percent(_window), do: nil

  defp credit_amount(%{credits: %{amount: amount}}) when is_number(amount), do: "$" <> :erlang.float_to_binary(amount / 1, decimals: 2)
  defp credit_amount(_window), do: nil

  defp credit_status(%{credits: %{status: status}}) when not is_nil(status), do: "#{status} balance"
  defp credit_status(_window), do: "balance unknown"

  # The design prints whole percentages. A window that is nearly but not fully
  # spent never rounds up to a full-looking 100%.
  defp percent_text(nil), do: ""
  defp percent_text(percent) when percent >= 100, do: "100%"
  defp percent_text(percent) when percent > 99, do: "99%"
  defp percent_text(percent) when percent > 0 and percent < 1, do: "<1%"
  defp percent_text(percent), do: "#{round(percent)}%"

  defp title_percent(nil), do: "usage unknown"
  defp title_percent(percent), do: "#{format_percent(percent)}% used"

  defp title_reset(nil), do: ""
  defp title_reset(reset), do: " · next reset #{reset}"

  defp format_percent(percent) do
    rounded = Float.round(percent / 1, 1)
    if rounded == trunc(rounded), do: Integer.to_string(trunc(rounded)), else: :erlang.float_to_binary(rounded, decimals: 1)
  end

  defp classes(names), do: names |> Enum.filter(&is_binary/1) |> Enum.join(" ")

  defp tone(percent) do
    case meter_class(percent, 80, 90) do
      "" -> nil
      class -> class
    end
  end

  defp bar_width(percent), do: percent |> max(0) |> min(100)

  defp reset_label(%DateTime{} = reset, %DateTime{} = now) do
    case DateTime.diff(reset, now, :second) do
      seconds when seconds <= 0 -> "now"
      seconds -> duration(seconds)
    end
  end

  defp reset_label(_reset, _now), do: nil

  # Two units at most, as the design prints them: "6d 15h", "4h 2m", "58m".
  defp duration(seconds) when seconds < @seconds_per_hour, do: "#{max(div(seconds, 60), 1)}m"
  defp duration(seconds) when seconds < @seconds_per_day, do: "#{div(seconds, @seconds_per_hour)}h #{div(rem(seconds, @seconds_per_hour), 60)}m"
  defp duration(seconds), do: "#{div(seconds, @seconds_per_day)}d #{div(rem(seconds, @seconds_per_day), @seconds_per_hour)}h"

  # The window length after the reset ("/5h", "/7d"), from the reported
  # duration or, failing that, the limit id Claude names its windows by.
  defp window_span(%{duration_minutes: minutes}) when is_integer(minutes) and minutes > 0 do
    cond do
      rem(minutes, 1_440) == 0 -> "#{div(minutes, 1_440)}d"
      rem(minutes, 60) == 0 -> "#{div(minutes, 60)}h"
      true -> "#{minutes}m"
    end
  end

  defp window_span(window) do
    limit_id = window |> Map.get(:limit_id, "") |> to_string()

    cond do
      String.contains?(limit_id, "five_hour") -> "5h"
      String.contains?(limit_id, "seven_day") -> "7d"
      true -> nil
    end
  end
end
